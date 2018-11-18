#!/usr/bin/env bash

TRY_LOOP="20"

# Install custom python package if requirements.txt is present
if [ -e "/requirements.txt" ]; then
    $(which pip) install --user -r /requirements.txt
fi

export PATH=$PATH:/usr/local/bin/:/usr/local/airflow

/usr/local/bin/aws configure set default.region ap-southeast-2 --debug

# Get the required parameters from AWS Parameter Store for RDS and Elasticache backends
REDIS_HOST=`/usr/local/bin/aws ssm get-parameter --name AIRFLOW_REDIS_HOST --with-decryption --region ap-southeast-2 | jq '.Parameter.Value'| tr -d '"'`
POSTGRES_HOST=`/usr/local/bin/aws ssm get-parameter --name AIRFLOW_POSTGRES_HOST --with-decryption --region ap-southeast-2 | jq '.Parameter.Value'| tr -d '"'`
POSTGRES_USER=`/usr/local/bin/aws ssm get-parameter --name AIRFLOW_POSTGRES_USER --with-decryption --region ap-southeast-2 | jq '.Parameter.Value'| tr -d '"'`
POSTGRES_PASSWORD=`/usr/local/bin/aws ssm get-parameter --name AIRFLOW_POSTGRES_PASSWORD --with-decryption --region ap-southeast-2 | jq '.Parameter.Value'| tr -d '"'`
POSTGRES_DB=`/usr/local/bin/aws ssm get-parameter --name AIRFLOW_POSTGRES_DB --with-decryption --region ap-southeast-2| jq '.Parameter.Value'| tr -d '"'`
METADATA_SETUP=`/usr/local/bin/aws ssm get-parameter --name AIRFLOW_METADATA_SETUP --region ap-southeast-2 | jq '.Parameter.Value' | tr -d '"'`

: "${REDIS_PORT:="6379"}"
: "${REDIS_PASSWORD:=""}"
#: "${REDIS_HOST:="redis"}"

: "${POSTGRES_PORT:="5432"}"
#: "${POSTGRES_HOST:="postgres"}"
#: "${POSTGRES_USER:="airflow"}"
#: "${POSTGRES_PASSWORD:="airflow"}"
#: "${POSTGRES_DB:="airflow"}"

# Defaults and back-compat
: "${AIRFLOW__CORE__EXECUTOR:=${EXECUTOR:-Sequential}Executor}"

if [ "$METADATA_SETUP" = "FALSE" ]; then
    : "${AIRFLOW__CORE__FERNET_KEY:=${FERNET_KEY:=$(python -c "from cryptography.fernet import Fernet; FERNET_KEY = Fernet.generate_key().decode(); print(FERNET_KEY)")}}"
    check=`/usr/local/bin/aws ssm put-parameter --name "AIRFLOW_CORE_FERNET_KEY" --type "String" --value $AIRFLOW__CORE__FERNET_KEY --overwrite --region ap-southeast-2`
else
    AIRFLOW__CORE__FERNET_KEY=`/usr/local/bin/aws ssm get-parameter --name AIRFLOW_CORE_FERNET_KEY --region ap-southeast-2 | jq '.Parameter.Value' | tr -d '"'`
fi 

export \
  AIRFLOW__CELERY__BROKER_URL \
  AIRFLOW__CELERY__RESULT_BACKEND \
  AIRFLOW__CORE__EXECUTOR \
  AIRFLOW__CORE__FERNET_KEY \
  AIRFLOW__CORE__LOAD_EXAMPLES \
  AIRFLOW__CORE__SQL_ALCHEMY_CONN \


# Load DAGs examples (default: Yes)
if [[ -z "$AIRFLOW__CORE__LOAD_EXAMPLES" && "${LOAD_EX:=n}" == n ]]
then
  AIRFLOW__CORE__LOAD_EXAMPLES=False
fi


if [ -n "$REDIS_PASSWORD" ]; then
    REDIS_PREFIX=:${REDIS_PASSWORD}@
else
    REDIS_PREFIX=
fi

wait_for_port() {
  local name="$1" host="$2" port="$3"
  local j=0
  while ! nc -z "$host" "$port" >/dev/null 2>&1 < /dev/null; do
    j=$((j+1))
    if [ $j -ge $TRY_LOOP ]; then
      echo >&2 "$(date) - $host:$port still not reachable, giving up"
      exit 1
    fi
    echo "$(date) - waiting for $name... $j/$TRY_LOOP"
    sleep 5
  done
}

wait_for_redis() {
  # Wait for Redis if we are using it
  if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]
  then
    wait_for_port "Redis" "$REDIS_HOST" "$REDIS_PORT"
  fi
}

if [ "$AIRFLOW__CORE__EXECUTOR" != "SequentialExecutor" ]; then
  AIRFLOW__CORE__SQL_ALCHEMY_CONN="postgresql+psycopg2://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB"
  AIRFLOW__CELERY__RESULT_BACKEND="db+postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB"
  wait_for_port "Postgres" "$POSTGRES_HOST" "$POSTGRES_PORT"
fi

if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]; then
  AIRFLOW__CELERY__BROKER_URL="redis://$REDIS_PREFIX$REDIS_HOST:$REDIS_PORT/1"
  wait_for_port "Redis" "$REDIS_HOST" "$REDIS_PORT"
fi

case "$1" in
  webserver)
    wait_for_port "Postgres" "$POSTGRES_HOST" "$POSTGRES_PORT"
    wait_for_redis
    if [ "$METADATA_SETUP" = "FALSE" ]; then
      airflow initdb
      python /create-user.py
      check=`/usr/local/bin/aws ssm put-parameter --name "AIRFLOW_METADATA_SETUP" --type "String" --value "TRUE" --overwrite --region ap-southeast-2` 
    fi 
    if [ "$AIRFLOW__CORE__EXECUTOR" = "LocalExecutor" ];
    then
      # With the "Local" executor it should all run in one container.
      airflow scheduler &
    fi
    exec airflow webserver  
    ;;
  worker|scheduler)
    wait_for_port "Postgres" "$POSTGRES_HOST" "$POSTGRES_PORT"
    wait_for_redis
    # To give the webserver time to run initdb.
    sleep 10
    exec airflow "$@"
    ;;
  flower)
    wait_for_redis
    exec airflow "$@"
    ;;
  version)
    exec airflow "$@"
    ;;
  *)
    # The command is something like bash, not an airflow subcommand. Just run it in the right environment.
    exec "$@"
    ;;
esac
