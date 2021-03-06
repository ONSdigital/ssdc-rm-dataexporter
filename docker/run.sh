#!/bin/bash
echo "running rm-dataexporter job $(date)"

# exit on errors, including unset variables (nounset)
set -o errexit  
set -o pipefail
# set -o nounset
# uncomment for trace
# set -o xtrace

FILENAME_DATE=$(date -u -d@"$(( `date -u +%s`-86400))" "+%Y-%m-%d")

if [ -z "$START_DATETIME" ]; then
  START_DATETIME=$(date -d@"$(( `date -u +%s`-86400))" "+%Y-%m-%dT00:00:00")
  echo "START_DATETIME: ${START_DATETIME} [default]"
else
  echo "START_DATETIME: ${START_DATETIME}"
fi

if [ -z "$END_DATETIME" ]; then
  END_DATETIME=$(date -u "+%Y-%m-%dT00:00:00")
  echo "END_DATETIME: ${END_DATETIME} [default]"
else
  echo "END_DATETIME: ${END_DATETIME}"

  # file naming to indicate between dates
  FILENAME_DATE="${START_DATETIME}_to_${END_DATETIME}"
fi

############################################################################
# REPLACE COLONS IN THE FILENAME DATE
# Some of the consuming systems can't handle colons in filenames so we need to sanitise the date strings
############################################################################
FILENAME_DATE=${FILENAME_DATE//:/-}

############################################################################
# PREPARE POSTGRES CERTIFICATES
# convert java pk8 required key format to pem if we're running in kubernetes
############################################################################
if [[ -f /root/.postgresql/postgresql.pk8 ]]; then
  echo "creating client-key.pem file from postgresql.pk8"
  openssl pkcs8 -in /root/.postgresql/postgresql.pk8 -inform der -nocrypt -out /tmp/client-key.pem
  chmod 600 /tmp/client-key.pem
fi

# run all data exports in persistent volume mounted directory
cd $PVC_MOUNT_PATH

######################################################################
# EXPORT UAC_QID_LINK TABLE AND UPLOAD FILE AND MANIFEST TO GCS BUCKET
######################################################################
echo "exporting uac_qid_link table content (no UACs)"


QID_FILE=qid_$FILENAME_DATE.json

PGPASSWORD=$DB_PASSWORD psql "sslmode=verify-ca sslrootcert=/root/.postgresql/root.crt sslcert=/root/.postgresql/postgresql.crt sslkey=/tmp/client-key.pem hostaddr=$DB_HOST port=$DB_PORT user=$DB_USERNAME dbname=rm" \
-c "\copy (SELECT row_to_json(t) FROM (SELECT id,qid,caze_id as case_id,active,created_at,last_updated_at FROM casev3.uac_qid_link where last_updated_at >= '$START_DATETIME' and last_updated_at < '$END_DATETIME') t) To '$QID_FILE';"


if [ -n "$DATAEXPORT_MI_BUCKET_NAME" ]
then
    echo "adding uac_qid_link file $QID_FILE to bucket $DATAEXPORT_MI_BUCKET_NAME"
    gsutil -q cp "$QID_FILE" gs://"$DATAEXPORT_MI_BUCKET_NAME"
fi


if [ -n "$DATAEXPORT_BUCKET_NAME" ]
then
  echo "zipping uac_qid_link file"

  filename=SSDCResponseManagement_qid_$FILENAME_DATE.gz
  gzip -c "$QID_FILE" > "$filename"

  echo "adding $filename to bucket $DATAEXPORT_BUCKET_NAME"
  gsutil -q cp "$filename" gs://"$DATAEXPORT_BUCKET_NAME"

  echo "write manifest $filename.manifest"

  cat > "$filename".manifest <<-EOF
{
  "schemaVersion": 1,
  "files": [
    {
      "sizeBytes": $(stat -c%s $filename),
      "md5sum": "$(openssl md5 "$filename" | awk '{ print $2 }')",
      "relativePath": "./",
      "name": "$filename"
    }
  ],
  "sourceName": "RM",
  "manifestCreated": "$(date +'%Y-%m-%dT%H:%M:%S').0000000Z",
  "description": "RM uac_qid_link table export",
  "dataset": "RM_cases",
  "version": 1
}
EOF


  echo "adding $filename.manifest to bucket $DATAEXPORT_BUCKET_NAME"
  gsutil -q cp "$filename".manifest gs://"$DATAEXPORT_BUCKET_NAME"

  # cleanup files
  rm "$filename".manifest
  rm $filename
fi

# cleanup file
rm $QID_FILE

######################################################################
# EXPORT CASES TABLE AND UPLOAD FILE AND MANIFEST TO GCS BUCKET
######################################################################
echo "exporting cases table content"


CASES_FILE=cases_$FILENAME_DATE.json

PGPASSWORD=$DB_PASSWORD psql "sslmode=verify-ca sslrootcert=/root/.postgresql/root.crt sslcert=/root/.postgresql/postgresql.crt sslkey=/tmp/client-key.pem hostaddr=$DB_HOST port=$DB_PORT user=$DB_USERNAME dbname=rm" \
-c "\copy (SELECT row_to_json(t) FROM (SELECT * FROM casev3.cases where last_updated_at >= '$START_DATETIME' and last_updated_at < '$END_DATETIME') t) To '$CASES_FILE';"


if [ -n "$DATAEXPORT_MI_BUCKET_NAME" ]
then
    echo "adding cases file $CASES_FILE to bucket $DATAEXPORT_MI_BUCKET_NAME"
    gsutil -q cp "$CASES_FILE" gs://"$DATAEXPORT_MI_BUCKET_NAME"
fi


if [ -n "$DATAEXPORT_BUCKET_NAME" ]
then
  echo "zipping cases file"

  filename=SSDCResponseManagement_case_$FILENAME_DATE.gz
  gzip -c "$CASES_FILE" > "$filename"

  echo "adding $filename to bucket $DATAEXPORT_BUCKET_NAME"
  gsutil -q cp "$filename" gs://"$DATAEXPORT_BUCKET_NAME"

  echo "write manifest $filename.manifest"

  cat > "$filename".manifest <<-EOF
{
  "schemaVersion": 1,
  "files": [
    {
      "sizeBytes": $(stat -c%s $filename),
      "md5sum": "$(openssl md5 "$filename" | awk '{ print $2 }')",
      "relativePath": "./",
      "name": "$filename"
    }
  ],
  "sourceName": "RM",
  "manifestCreated": "$(date +'%Y-%m-%dT%H:%M:%S').0000000Z",
  "description": "RM cases table export",
  "dataset": "RM_cases",
  "version": 1
}
EOF

  echo "adding $filename.manifest to bucket $DATAEXPORT_BUCKET_NAME"
  gsutil -q cp "$filename".manifest gs://"$DATAEXPORT_BUCKET_NAME"

  # cleanup files
  rm $filename
  rm "$filename".manifest
fi

# cleanup file
rm $CASES_FILE

######################################################################
# EXPORT EVENT TABLE AND UPLOAD FILE AND MANIFEST TO GCS BUCKET
######################################################################
echo "exporting event table content"


EVENTS_FILE=events_$FILENAME_DATE.json

PGPASSWORD=$DB_PASSWORD psql "sslmode=verify-ca sslrootcert=/root/.postgresql/root.crt sslcert=/root/.postgresql/postgresql.crt sslkey=/tmp/client-key.pem hostaddr=$DB_HOST port=$DB_PORT user=$DB_USERNAME dbname=rm" \
-c "\copy (SELECT row_to_json(t) FROM (SELECT * FROM casev3.event where type!='CASE_CREATED' and type!='UAC_UPDATED' and type!='SAMPLE_LOADED' and type!='RM_UAC_CREATED' and processed_at >= '$START_DATETIME' and processed_at < '$END_DATETIME') t) To '$EVENTS_FILE';"


if [ -n "$DATAEXPORT_MI_BUCKET_NAME" ]
then
    echo "adding event file $EVENTS_FILE to bucket $DATAEXPORT_MI_BUCKET_NAME"
    gsutil -q cp "$EVENTS_FILE" gs://"$DATAEXPORT_MI_BUCKET_NAME"
fi


if [ -n "$DATAEXPORT_BUCKET_NAME" ]
then
  echo "zipping event file"

  filename=SSDCResponseManagement_events_$FILENAME_DATE.gz
  gzip -c "$EVENTS_FILE" > "$filename"

  echo "adding $filename to bucket $DATAEXPORT_BUCKET_NAME"
  gsutil -q cp "$filename" gs://"$DATAEXPORT_BUCKET_NAME"

  echo "write manifest $filename.manifest"

  cat > "$filename".manifest <<-EOF
{
  "schemaVersion": 1,
  "files": [
    {
      "sizeBytes": $(stat -c%s $filename),
      "md5sum": "$(openssl md5 "$filename" | awk '{ print $2 }')",
      "relativePath": "./",
      "name": "$filename"
    }
  ],
  "sourceName": "RM",
  "manifestCreated": "$(date +'%Y-%m-%dT%H:%M:%S').0000000Z",
  "description": "RM event table export",
  "dataset": "RM_cases",
  "version": 1
}
EOF

  echo "adding $filename.manifest to bucket $DATAEXPORT_BUCKET_NAME"
  gsutil -q cp "$filename".manifest gs://"$DATAEXPORT_BUCKET_NAME"

  # cleanup files
  rm $filename
  rm "$filename".manifest
fi

echo "file export complete"

# cleanup file
rm $EVENTS_FILE
