#!/bin/bash

# Blueprint BUILD command

shift

#
# Read arguments
#

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help)
            printf "build [options]\t\tBuild containerized technology stack defined in docker-blueprint.yml\n"
            exit
    esac

    shift
done

#
# Initialize path variables
#

printf "Pulling blueprint..."

read_value BLUEPRINT 'blueprint.name' && printf "."
read_value CHECKPOINT 'blueprint.version' && printf "."
read_value ENV_NAME 'blueprint.env' && printf "."
read_array MODULES_TO_LOAD 'modules' && printf "."

BLUEPRINT_DIR=$(AS_FUNCTION=true bash $ENTRYPOINT pull $BLUEPRINT)

if [[ $? -ne 0 ]]; then
    printf "\n${RED}ERROR${RESET}: Unable to pull blueprint '$BLUEPRINT'.\n"
    exit 1
fi

printf " done\n"

if [[ -n $CHECKPOINT ]]; then
    cd $BLUEPRINT_DIR
    git checkout $CHECKPOINT 2> /dev/null
    if [[ $? -eq 0 ]]; then
        echo "Version: $CHECKPOINT"
    else
        printf "${YELLOW}Warning${RESET}: unable to checkout version $CHECKPOINT\n"
    fi
    cd $PROJECT_DIR
fi

if [[ -n "$ENV_NAME" ]]; then
    ENV_DIR=$BLUEPRINT_DIR/env/$ENV_NAME
fi

#
# Read generated configuration
#

printf "Reading configuration..."

read_value DEFAULT_SERVICE "default_service" && printf "."
read_keys DEPENDENCIES_KEYS "dependencies" && printf "."
read_keys PURGE_KEYS "purge" && printf " done\n"

echo "$DEFAULT_SERVICE" > "$DIR/default_service"

#
# Build docker-compose.yml
#

printf "Building docker-compose.yml..."

cp "$BLUEPRINT_DIR/templates/docker-compose.yml" "$PWD/docker-compose.yml"

chunk="$BLUEPRINT_DIR" \
perl -0 -i -pe 's/#\s*(.*)\$BLUEPRINT_DIR/$1$ENV{"chunk"}/g' \
"$PWD/docker-compose.yml" && printf "."

# Replace 'environment' placeholders

CHUNK="$(yq read -p pv $BLUEPRINT_FILE_FINAL 'environment' | pr -To 4)"
chunk="$CHUNK" perl -0 -i -pe 's/ *# environment:root/$ENV{"chunk"}/' \
"$PWD/docker-compose.yml" && printf "."

CHUNK="$(yq read -p v $BLUEPRINT_FILE_FINAL 'environment' | pr -To 6)"
chunk="$CHUNK" perl -0 -i -pe 's/ *# environment/$ENV{"chunk"}/' \
"$PWD/docker-compose.yml" && printf "."

# Replace 'services' placeholders

CHUNK="$(yq read -p pv $BLUEPRINT_FILE_FINAL 'services')"
chunk="$CHUNK" perl -0 -i -pe 's/ *# services:root/$ENV{"chunk"}/' \
"$PWD/docker-compose.yml" && printf "."

CHUNK="$(yq read -p v $BLUEPRINT_FILE_FINAL 'services' | pr -To 2)"
chunk="$CHUNK" perl -0 -i -pe 's/ *# services/$ENV{"chunk"}/' \
"$PWD/docker-compose.yml" && printf "."

# Replace 'volumes' placeholders

CHUNK="$(yq read -p pv $BLUEPRINT_FILE_FINAL 'volumes')"
chunk="$CHUNK" perl -0 -i -pe 's/ *# volumes:root/$ENV{"chunk"}/' \
"$PWD/docker-compose.yml" && printf "."

CHUNK="$(yq read -p v $BLUEPRINT_FILE_FINAL 'volumes' | pr -To 2)"
chunk="$CHUNK" perl -0 -i -pe 's/ *# volumes/$ENV{"chunk"}/' \
"$PWD/docker-compose.yml" && printf "."

# Remove empty lines

sed -ri '/^\s*$/d' "$PWD/docker-compose.yml"

printf " done\n"

#
# Build dockerfile
#

printf "Building dockerfile...\n"

cp "$BLUEPRINT_DIR/templates/dockerfile" "$PWD/dockerfile"

CHUNK="$(yq read -p v $BLUEPRINT_FILE_FINAL 'stages.development[*]')"
chunk="$CHUNK" perl -0 -i -pe 's/ *# \$DEVELOPMENT_COMMANDS/$ENV{"chunk"}/' \
"$PWD/dockerfile"

CHUNK="$(yq read -p v $BLUEPRINT_FILE_FINAL 'stages.production[*]')"
chunk="$CHUNK" perl -0 -i -pe 's/ *# \$PRODUCTION_COMMANDS/$ENV{"chunk"}/' \
"$PWD/dockerfile"

for key in "${DEPENDENCIES_KEYS[@]}"; do
    read_array DEPS "dependencies.$key"
    key=$(echo "$key" | tr [:lower:] [:upper:])
    printf "DEPS_$key: ${DEPS[*]}\n"

    key="$key" chunk="${DEPS[*]}" \
    perl -0 -i -pe 's/#\s*(.*)\$DEPS_$ENV{"key"}/$1$ENV{"chunk"}/g' \
    "$PWD/dockerfile"
done

for key in "${PURGE_KEYS[@]}"; do
    read_array PURGE "purge.$key"
    key=$(echo "$key" | tr [:lower:] [:upper:])
    printf "PURGE_$key: ${PURGE[*]}\n"

    key="$key" chunk="${PURGE[*]}" \
    perl -0 -i -pe 's/#\s*(.*)\$PURGE_$ENV{"key"}/$1$ENV{"chunk"}/g' \
    "$PWD/dockerfile"
done

chunk="$BLUEPRINT_DIR" \
perl -0 -i -pe 's/#\s*(.*)\$BLUEPRINT_DIR/$1$ENV{"chunk"}/g' \
"$PWD/dockerfile"

printf "done\n"

#
# Build containers
#

BUILD_ARGS=()

BUILD_ARGS+=("--build-arg BLUEPRINT_DIR=$BLUEPRINT_DIR")

read_keys BUILD_ARGS_KEYS 'build_args'

for variable in ${BUILD_ARGS_KEYS[@]}; do
    read_value value "build_args.$variable"

    if [[ -n ${!variable+x} ]]; then
        value="${!variable:-}"
    fi

    BUILD_ARGS+=("--build-arg $variable=$value")
done

docker-compose build ${BUILD_ARGS[@]}

echo "Removing existing stack..."

docker-compose down

echo "Building new stack..."

bash $ENTRYPOINT up -d

#
# Restart container to apply chown
#

echo "Restarting container '$DEFAULT_SERVICE'..."
docker-compose restart "$DEFAULT_SERVICE"

#
# Run initialization scripts
#

if [[ -d $ENV_DIR && -f "$ENV_DIR/before.sh" ]]; then
    echo "Initializing environment before modules..."
    ENV_DIR=$ENV_DIR bash "$ENV_DIR/before.sh"
elif [[ -d $BLUEPRINT_DIR && -f "$BLUEPRINT_DIR/before.sh" ]]; then
    echo "Initializing blueprint before modules..."
    BLUEPRINT_DIR=$BLUEPRINT_DIR bash "$BLUEPRINT_DIR/before.sh"
fi

for module in "${MODULES_TO_LOAD[@]}"; do
    if [[ -f "$BLUEPRINT_DIR/modules/$module/init.sh" ]]; then
        echo "Initializing module '$module'..."
        MODULE_DIR="$BLUEPRINT_DIR/modules/$module" \
        bash "$BLUEPRINT_DIR/modules/$module/init.sh"
    fi

    if [[ -f "$ENV_DIR/modules/$module/init.sh" ]]; then
        echo "Initializing environment module '$module'..."
        MODULE_DIR="$ENV_DIR/modules/$module" \
        bash "$ENV_DIR/modules/$module/init.sh"
    fi
done

if [[ -d $ENV_DIR && -f "$ENV_DIR/after.sh" ]]; then
    echo "Initializing environment after modules..."
    ENV_DIR=$ENV_DIR bash "$ENV_DIR/after.sh"
elif [[ -d $BLUEPRINT_DIR && -f "$BLUEPRINT_DIR/after.sh" ]]; then
    echo "Initializing blueprint after modules..."
    BLUEPRINT_DIR=$BLUEPRINT_DIR bash "$BLUEPRINT_DIR/after.sh"
fi

#
# Comment .env variables that collide with docker-compose environment
#

if [[ -f .env ]]; then
    readarray -t VARIABLES < <(yq read -p p "$BLUEPRINT_FILE_FINAL" "environment.*")

    for variable in "${VARIABLES[@]}"; do
        v="${variable#'environment.'}" \
        perl -i -pe 's/^(?!#)(\s*$ENV{v})/# $1/' .env
    done

    echo "Commented environment variables used by Docker"
fi