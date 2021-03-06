#!/bin/bash

# Validation of inputs upfront
if [ -z $BUCKET ] ; then
   echo "You must specify a bucket, such as gs://my-backups/"
   exit 1
fi

if [ -z $DATABASE ]; then
    echo "You must specify a DATABASE list such as neo4j,system"
    exit 1
fi

if [ -z $TIMESTAMP ]; then
    echo "No TIMESTAMP was provided, we are using latest"
    TIMESTAMP=latest
fi

if [ -z $GOOGLE_APPLICATION_CREDENTIALS ] ; then
    echo "Setting default google credential location to /auth/credentials.json"
    export GOOGLE_APPLICATION_CREDENTIALS=/auth/credentials.json
fi

if [ -z $PURGE_ON_COMPLETE ]; then
    echo "Setting PURGE_ON_COMPLETE=true"
    PURGE_ON_COMPLETE=true
fi

function restore_database {
    db=$1

    echo ""
    echo "=== RESTORE $db"

    if [ -d "/data/databases/$db" ] ; then
        echo "You have an existing graph database at /data/databases/$db"

        if [ "$FORCE_OVERWRITE" != "true" ] ; then
            echo "And you have not specified FORCE_OVERWRITE=true, so we will not restore because"
            echo "that would overwrite your existing data.   Exiting.".
            return
        fi
    else 
        echo "No existing graph database found at /data/databases/$db"
    fi

    # Pass the force flag to the restore operation, which will overwrite
    # whatever is there, if and only if FORCE_OVERWRITE=true.
    if [ "$FORCE_OVERWRITE" = true ]; then
        echo "We will be force-overwriting any data present"
        FORCE_FLAG="--force"
    else
        # Pass no flag in any other setup.
        echo "We will not force-overwrite data if present"
        FORCE_FLAG=""
    fi

    RESTORE_ROOT=/data/.restore

    echo "Making restore directory"
    mkdir -p "$RESTORE_ROOT"

    # Trim trailing slash from BUCKET if it's there, because it messes up the
    # copy commands if you copy gs://a//foo to gs://a//bar (double slash in path)
    # https://stackoverflow.com/a/17542946/2920686
    if [ "${BUCKET: -1}" = "/" ]; then
        BUCKET="${BUCKET%?}"
    fi

    REMOTE_BACKUPSET="$BUCKET/$db-$TIMESTAMP.tar.gz"
    echo "Copying $REMOTE_BACKUPSET -> $RESTORE_ROOT"

    # By copying recursively, the user can specify a dir with an uncompressed
    # backup if preferred. The -m flag downloads in parallel if possible.
    gsutil -m cp -r "$REMOTE_BACKUPSET" "$RESTORE_ROOT"

    if [ $? -ne 0 ] ; then
        echo "Copy remote backupset $REMOTE_BACKUPSET FAILED"
        echo "Cannot restore $db"
        return
    fi

    echo "Backup size pre-uncompress:"
    du -hs "$RESTORE_ROOT"
    ls -l "$RESTORE_ROOT"

    # Important note!  If you have a backup name that is "foo.tar.gz" or 
    # foo.zip, we need to assume that this unarchives to a directory called
    # foo, as neo4j backup sets are directories.  So we'll remove the suffix
    # after unarchiving and use that as the actual backup target.
    BACKUP_FILENAME=$(basename "$REMOTE_BACKUPSET")
    RESTORE_FROM=uninitialized
    if [[ $BACKUP_FILENAME =~ \.tar\.gz$ ]] ; then
        echo "Untarring backup file"
        cd "$RESTORE_ROOT" && tar --force-local --overwrite -zxvf "$BACKUP_FILENAME"

        if [ $? -ne 0 ] ; then
            echo "Failed to unarchive target backup set"
            echo "FAILED TO RESTORE $db"
            return
        fi

        # foo-$TIMESTAMP.tar.gz untars/zips to a directory called foo.
        UNTARRED_BACKUP_DIR=$db

        if [ -z $BACKUP_SET_DIR ] ; then
            echo "BACKUP_SET_DIR was not specified, so I am assuming this backup set was formatted by my backup utility"
            RESTORE_FROM="$RESTORE_ROOT/data/$UNTARRED_BACKUP_DIR"
        else 
            RESTORE_FROM="$RESTORE_ROOT/$BACKUP_SET_DIR"
        fi
    elif [[ $BACKUP_FILENAME =~ \.zip$ ]] ; then
        echo "Unzipping backupset"
        cd "$RESTORE_ROOT" && unzip -o "$BACKUP_FILENAME"
        
        if [ $? -ne 0 ]; then 
            echo "Failed to unzip target backup set"
            echo "FAILED TO RESTORE $db"
            return
        fi

        # Remove file extension, get to directory name  
        UNZIPPED_BACKUP_DIR=${BACKUP_FILENAME%.zip}

        if [ -z $BACKUP_SET_DIR ] ; then
            echo "BACKUP_SET_DIR was not specified, so I am assuming this backup set was formatted by my backup utility"
            RESTORE_FROM="$RESTORE_ROOT/data/$db"
        else
            RESTORE_FROM="$RESTORE_ROOT/$BACKUP_SET_DIR"
        fi
    else
        # If user stores backups as uncompressed directories, we would have pulled down the entire directory
        echo "This backup $BACKUP_FILENAME looks uncompressed."
        RESTORE_FROM="$RESTORE_ROOT/$BACKUP_FILENAME"
    fi

    echo "BACKUP_FILENAME=$BACKUP_FILENAME"
    echo "UNTARRED_BACKUP_DIR=$UNTARRED_BACKUP_DIR"
    echo "UNZIPPED_BACKUP_DIR=$UNZIPPED_BACKUP_DIR"
    echo "RESTORE_FROM=$RESTORE_FROM"

    echo "Set to restore from $RESTORE_FROM - size on disk:"
    du -hs "$RESTORE_FROM"

    cd /data && \
    echo "Dry-run command"
    echo neo4j-admin restore \
        --from="$RESTORE_FROM" \
        --database="$db" $FORCE_FLAG \
        --verbose

    # This data is output because of the way neo4j-admin works.  It writes the restored set to
    # /var/lib/neo4j by default.  This can fail if volumes aren't sized appropriately, so this 
    # aids in debugging.
    echo "Volume mounts and sizing"
    df -h

    echo "Now restoring"
    neo4j-admin restore \
        --from="$RESTORE_FROM" \
        --database="$db" $FORCE_FLAG \
        --verbose

    RESTORE_EXIT_CODE=$?

    if [ "$RESTORE_EXIT_CODE" -ne 0 ]; then 
        echo "Restore process failed; will not continue"
        echo "Failed to restore $db"
        return $RESTORE_EXIT_CODE
    fi

    # Shell utils automatically place data in /var/lib/neo4j -- this is problematic in docker,
    # because it needs to be in /data per the docker spec.  This can get squirrely when users
    # have volume mounts set up in certain ways.
    echo "Rehoming database $db"
    # echo "Restored to:"
    # ls -l /var/lib/neo4j/data/databases
    # echo "TRANSACTIONS:"
    # ls -l /var/lib/neo4j/data/transactions

    # Destination docker directories.
    mkdir -p /data/databases
    mkdir -p /data/transactions

    # Danger: we are destroying previous data on disk.  On purpose.
    # Optional: you can move the database out of the way to preserve the data just in case,
    # but we don't do it this way because for large DBs this will just rapidly fill the disk
    # and cause out of disk errors.
    for loc in databases transactions ; do
        if [ -d "/data/$loc/$db" ] ; then
            if [ "$FORCE_OVERWRITE" = "true" ] ; then
                echo "Removing previous $loc because FORCE_OVERWRITE=true"
                rm -rf "/data/$loc/$db"
            fi
        fi
    done

    mv "/var/lib/neo4j/data/databases/$db" /data/databases/
    mv "/var/lib/neo4j/data/transactions/$db" /data/transactions/

    # Modify permissions/group, because we're running as root.
    chown -R neo4j /data/databases 
    chown -R neo4j /data/transactions
    chgrp -R neo4j /data/databases 
    chgrp -R neo4j /data/transactions

    echo "Final permissions"
    ls -al "/data/databases/$db"
    ls -al "/data/transactions/$db"

    echo "Final size"
    du -hs "/data/databases/$db"
    du -hs "/data/transactions/$db"

    if [ "$PURGE_ON_COMPLETE" = true ] ; then
        echo "Purging backupset from disk"
        rm -rf "$RESTORE_ROOT"
    fi

    echo "RESTORE OF $db COMPLETE"
}

echo "=============== Restore ==============================="
echo "GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS"
echo "TIMESTAMP=$TIMESTAMP"
echo "BUCKET=$BUCKET"
echo "FORCE_OVERWRITE=$FORCE_OVERWRITE"
echo "PURGE_ON_COMPLETE=$PURGE_ON_COMPLETE"
echo "Starting point database contents: "
ls /data/databases
echo "Starting point transactions: "
ls /data/transactions
echo "============================================================"

echo "Activating google credentials before beginning"
ls -l $GOOGLE_APPLICATION_CREDENTIALS
gcloud auth activate-service-account --key-file "$GOOGLE_APPLICATION_CREDENTIALS"

if [ $? -ne 0 ] ; then
    echo "Credentials failed; copying from Google will likely fail unless the bucket is public"
    echo "Ensure GOOGLE_APPLICATION_CREDENTIALS is appropriately set."
fi

# See: https://neo4j.com/docs/operations-manual/current/backup/restoring/#backup-restoring-cluster
echo "Unbinding previous cluster state, if applicable"
neo4j-admin unbind

# Split by comma
IFS=","
read -a databases <<< "$DATABASE"
for db in "${databases[@]}"; do  
   restore_database "$db"
done

echo "All finished"
exit 0
