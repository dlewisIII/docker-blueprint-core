#!/bin/bash

# Blueprint BUILD command

shift

#
# Read arguments
#

MODE_FORCE=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help)
            printf "${CMD_COL}build${RESET} [${FLG_COL}options${RESET}]"
            printf "\t\tBuild containerized technology stack defined in docker-blueprint.yml\n"

            printf "  ${FLG_COL}-f${RESET}, ${FLG_COL}--force${RESET}"
            printf "\t\t\tAlways generate new docker files\n"

            exit

            ;;
        -f|--force)
            MODE_FORCE=true
            ;;
    esac

    shift
done

#
# Initialize path variables
#

printf "Loading blueprint..."

yq_read_value BLUEPRINT 'blueprint.name' && printf "."
yq_read_value CHECKPOINT 'blueprint.version' && printf "."
yq_read_value ENV_NAME 'blueprint.env' && printf "."
yq_read_array MODULES_TO_LOAD 'modules' && printf "."

BLUEPRINT_DIR=$(AS_FUNCTION=true bash $ENTRYPOINT pull $BLUEPRINT)

if [[ $? -ne 0 ]]; then
    printf "\n${RED}ERROR${RESET}: Unable to pull blueprint '$BLUEPRINT'.\n"
    exit 1
fi

printf " ${GREEN}done${RESET}\n"

# Set the blueprint repository to the version specified.
# This allows to always safely reproduce previous versions of the blueprint.
if [[ -n $CHECKPOINT ]]; then
    cd $BLUEPRINT_DIR
    git checkout $CHECKPOINT 2> /dev/null
    if [[ $? -eq 0 ]]; then
        printf "Version: ${CYAN}$CHECKPOINT${RESET}\n"
    else
        printf "${RED}ERROR${RESET}: Unable to checkout version $CHECKPOINT\n"
        exit 1
    fi
    cd $PROJECT_DIR
fi

# Set the project environment directory
if [[ -n "$ENV_NAME" ]]; then
    ENV_DIR=$BLUEPRINT_DIR/env/$ENV_NAME

    if [[ ! -d $ENV_DIR ]]; then
        printf "${RED}ERROR${RESET}: Environment ${YELLOW}$ENV_NAME${RESET} doesn't exist\n"
        exit 1
    fi
fi

#
# Read generated configuration
#

printf "Reading configuration..."

yq_read_value DEFAULT_SERVICE "default_service" && printf "."
yq_read_keys DEPENDENCIES_KEYS "dependencies" && printf "."
yq_read_keys BUILD_ARGS_KEYS "build_args" && printf "."
yq_read_keys PURGE_KEYS "purge" && printf " ${GREEN}done${RESET}\n"

echo "$DEFAULT_SERVICE" > "$DIR/default_service"

BUILD_ARGS=()

BUILD_ARGS+=("--build-arg BLUEPRINT_DIR=$BLUEPRINT_DIR")

SCRIPT_VARS=()
SCRIPT_VARS+=("ENV_DIR=$ENV_DIR")
SCRIPT_VARS+=("BLUEPRINT_DIR=$BLUEPRINT_DIR")

for variable in ${BUILD_ARGS_KEYS[@]}; do
    yq_read_value value "build_args.$variable"

    # Replace build argument value with env variable value if it is set
    if [[ -n ${!variable+x} ]]; then
        value="${!variable:-}"
    fi

    BUILD_ARGS+=("--build-arg $variable=$value")
    SCRIPT_VARS+=("$variable=$value")
done

#
# Build docker-compose.yml
#

printf "Building docker-compose files...\n"

yq_read_keys STAGES "stages"

for stage in "${STAGES[@]}"; do
    DOCKER_COMPOSE_FILE="docker-compose.yml"

    if [[ "$stage" != "base" ]]; then
        DOCKER_COMPOSE_FILE="docker-compose.$stage.yml"
    fi

    CURRENT_DOCKER_COMPOSE_FILE="$PWD/$DOCKER_COMPOSE_FILE"

    if $MODE_FORCE; then
        rm -f "$CURRENT_DOCKER_COMPOSE_FILE"
    elif [[ -f "$CURRENT_DOCKER_COMPOSE_FILE" ]]; then
        printf "${YELLOW}WARNING${RESET}: $DOCKER_COMPOSE_FILE already exists, skipping generation (run with --force to override).\n"
    fi

    if [[ -f "$BLUEPRINT_DIR/$DOCKER_COMPOSE_FILE" ]] && \
        [[ ! -f "$CURRENT_DOCKER_COMPOSE_FILE" ]]; then
        cp -f "$BLUEPRINT_DIR/$DOCKER_COMPOSE_FILE" "$CURRENT_DOCKER_COMPOSE_FILE"

        for module in "${MODULES_TO_LOAD[@]}"; do
            MODULE_DOCKER_COMPOSE_FILE="$BLUEPRINT_DIR/modules/$module/$DOCKER_COMPOSE_FILE"

            if [[ -f "$MODULE_DOCKER_COMPOSE_FILE" ]]; then
                printf -- "$(
                    yq_merge \
                    "$CURRENT_DOCKER_COMPOSE_FILE" "$MODULE_DOCKER_COMPOSE_FILE"
                )" > "$CURRENT_DOCKER_COMPOSE_FILE"
            fi
        done

        # Remove empty lines

        sed -ri '/^\s*$/d' "$CURRENT_DOCKER_COMPOSE_FILE"

        printf "Generated ${YELLOW}$DOCKER_COMPOSE_FILE${RESET}\n"
    fi
done

#
# Build dockerfile
#

printf "Building dockerfile..."

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
    printf "."

    key="$key" chunk="${DEPS[*]}" \
    perl -0 -i -pe 's/#\s*(.*)\$DEPS_$ENV{"key"}/$1$ENV{"chunk"}/g' \
    "$PWD/dockerfile"
done

for key in "${PURGE_KEYS[@]}"; do
    read_array PURGE "purge.$key"
    key=$(echo "$key" | tr [:lower:] [:upper:])
    printf "."

    key="$key" chunk="${PURGE[*]}" \
    perl -0 -i -pe 's/#\s*(.*)\$PURGE_$ENV{"key"}/$1$ENV{"chunk"}/g' \
    "$PWD/dockerfile"
done

chunk="$BLUEPRINT_DIR" \
perl -0 -i -pe 's/#\s*(.*)\$BLUEPRINT_DIR/$1$ENV{"chunk"}/g' \
"$PWD/dockerfile"

printf " ${GREEN}done${RESET}\n"

#
# Build containers
#

$DOCKER_COMPOSE build ${BUILD_ARGS[@]}
