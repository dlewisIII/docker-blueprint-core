#!/bin/bash

EXECUTABLE_NAME=$(basename "${BASH_SOURCE%.sh}")

DIR=.docker-blueprint

mkdir -p $DIR

if [[ -z $UID ]]; then
    UID=$(id -u)
fi

if [[ -z "$GID" ]]; then
    GID=$(id -g)
fi

yq() {
    docker run --rm -i -v "${PWD}":/workdir mikefarah/yq yq "$@"
}

read_value() {
    if [[ -z "$3" ]]; then
        FILE="$BLUEPRINT_FILE_FINAL"
    else
        FILE="$3"
    fi

    printf -v "$1" "$(yq read "$FILE" "$2" 2>/dev/null)"
}

read_array() {
    if [[ -z "$3" ]]; then
        FILE="$BLUEPRINT_FILE_FINAL"
    else
        FILE="$3"
    fi
    
    readarray -t "$1" < <(yq read "$FILE" "$2[*]")
}

read_keys() {
    if [[ -z "$3" ]]; then
        FILE="$BLUEPRINT_FILE_FINAL"
    else
        FILE="$3"
    fi
    
    readarray -t "$1" < <(yq read "$FILE" "$2" --tojson | \
                        jq -r '. | keys[]')
}

init_default_service() {
    DEFAULT_SERVICE=$(cat $DIR/default_service 2>/dev/null)

    if [[ -z $DEFAULT_SERVICE ]] && [[ -f docker-blueprint.yml ]]; then
        read_value DEFAULT_SERVICE "default_service" docker-blueprint.yml
    fi
}

if [[ -z "$DEFAULT_SERVICE" ]]; then
    init_default_service
fi

case $1 in
    create)
        
        shift

        if [[ -z "$1" ]]; then
            echo "Usage: $EXECUTABLE_NAME create <blueprint>"
            exit 1
        fi

        BLUEPRINT=$1

        shift

        #
        # Read arguments
        #

        while [[ "$#" -gt 0 ]]; do
            case $1 in
                -m|--with)
                    ARG_WITH=()
                    
                    while [[ -n "$2" ]] && [[ "$2" != -* ]]; do
                        ARG_WITH+=($2)
                        shift
                    done

                    if [[ -z "${ARG_WITH[0]}" ]]; then
                        echo "Usage: $EXECUTABLE_NAME create <blueprint> --with <modules>"
                        exit 1
                    fi
                    
                    ;;

                -e|--env)
                    ENV_NAME=$2
                    shift

                    if [[ -z "$ENV_NAME" ]]; then
                        echo "Usage: $EXECUTABLE_NAME create <blueprint> --env <name> --with <modules>"
                        exit 1
                    fi
            esac

            shift
        done

        if [[ -n "$ENV_NAME" ]] && [[ -z "$ARG_WITH" ]]; then
            echo "Notice: --with argument not specified."
            echo "Setting environment has no effect."
            exit 1
        fi

        mkdir -p $DIR/blueprints

        #
        # Initialize path variables
        #

        BLUEPRINT_DIR=$DIR/blueprints/$BLUEPRINT
        BLUEPRINT_FILE_TMP=$DIR/blueprints/$BLUEPRINT/blueprint.tmp
        BLUEPRINT_FILE_BASE=$DIR/blueprints/$BLUEPRINT/blueprint.yml
        BLUEPRINT_FILE_FINAL=docker-blueprint.yml

        if [[ -n "$ENV_NAME" ]]; then
            ENV_DIR=$DIR/blueprints/$BLUEPRINT/env/$ENV_NAME
        fi

        #
        # Build custom blueprint file
        # 
        # Generate only when file is not present
        # or force rebuild when modules have changed

        if ! [[ -f docker-blueprint.yml ]] || [[ -n "$ARG_WITH" ]]; then

            printf "Generating blueprint file..."

            # Merge environment preset with technology preset
                
            if [[ -f "$ENV_DIR/blueprint.yml" ]]; then
                printf -- "$(yq merge -a $BLUEPRINT_FILE_BASE $ENV_DIR/blueprint.yml)" > "$BLUEPRINT_FILE_TMP"
            else
                cp "$BLUEPRINT_FILE_BASE" "$BLUEPRINT_FILE_TMP"
            fi

            # Collect modules to load from
            # temporary preset file and CLI arguments

            read_array MODULES "modules" "$BLUEPRINT_FILE_TMP" && printf "."

            MODULES_TO_LOAD=()

            for module in "${MODULES[@]}"; do
                MODULES_TO_LOAD+=($module)
            done

            for module in "${ARG_WITH[@]}"; do
                MODULES_TO_LOAD+=($module)
            done

            # Rearrange modules according to depends_on
            # such as dependencies always come first
            # Notice: cyclic dependencies WILL cause undefined behavior

            i=0
            MODULE_STACK=()

            while [[ $i < ${#MODULES_TO_LOAD[@]} ]]; do

                module="${MODULES_TO_LOAD[i]}"
                
                FOUND=false

                for entry in "${MODULE_STACK[@]}"; do
                    if [[ $entry == $module ]]; then
                        FOUND=true; break
                    fi
                done

                if ! $FOUND; then
                    MODULE_STACK+=("$module")
                fi

                # Read depends_on from each module file
                
                if [[ -f "$BLUEPRINT_DIR/modules/$module.yml" ]]; then
                    read_array DEPENDS_ON 'depends_on' "$BLUEPRINT_DIR/modules/$module.yml"
                    
                    FOUND=false

                    # For each dependency, check whether it
                    # already has been added to the list
                    
                    for dependency in "${DEPENDS_ON[@]}"; do
                        FOUND=false

                        for entry in "${MODULE_STACK[@]}"; do
                            if [[ $entry == $dependency ]]; then
                                FOUND=true; break
                            fi
                        done

                        # If dependency has not been already added,
                        # replace current module with the dependency
                        # and append module to the end of the list
                        
                        if ! $FOUND; then
                            stack_length=${#MODULE_STACK[@]}
                            MODULE_STACK[stack_length - 1]="$dependency"
                            MODULE_STACK+=("$module")
                        fi
                    done
                fi

                ((i = i + 1))
                
                printf "."

            done

            printf " done\n"

            MODULES_TO_LOAD=("${MODULE_STACK[@]}")
            
            # Generate a list of YAML files to merge
            # depending on chosen modules

            FILES_TO_MERGE=("$BLUEPRINT_FILE_TMP")

            function append_file_to_merge {
                if [[ -f "$1" ]]; then
                    FILES_TO_MERGE+=("$1")
                fi
            }

            for module in "${MODULES_TO_LOAD[@]}"; do
                
                # Each module can extend preset YAML file
                
                append_file_to_merge "$BLUEPRINT_DIR/modules/$module.yml"

                # If environment is specified, additionally load module
                # configuration files specific to the environment

                if [[ -d "$ENV_DIR" ]]; then
                    append_file_to_merge "$ENV_DIR/modules/$module.yml"
                fi
            done

            if [[ -z "${FILES_TO_MERGE[1]}" ]]; then
                printf -- "$(yq read "${FILES_TO_MERGE[0]}")" > "$BLUEPRINT_FILE_FINAL"
            else
                printf -- "$(yq merge -a ${FILES_TO_MERGE[@]})" > "$BLUEPRINT_FILE_FINAL"
            fi

            printf -- "$(yq delete $BLUEPRINT_FILE_FINAL 'modules')" > "$BLUEPRINT_FILE_FINAL"
            printf -- "$(yq delete $BLUEPRINT_FILE_FINAL 'depends_on')" > "$BLUEPRINT_FILE_FINAL"
        fi

        rm -f "$BLUEPRINT_FILE_TMP"

        #
        # Read generated configuration
        #

        printf "Reading configuration..."

        read_value DEFAULT_SERVICE "default_service" && printf "."
        read_value SYNC_USER "user" && printf "."
        read_array MAKE_DIRS "make_dirs" && printf "."
        read_array POSTBUILD_COMMANDS "postbuild_commands" && printf "."
        read_keys DEPENDENCIES_KEYS "dependencies" && printf "."
        read_keys PURGE_KEYS "purge" && printf " done\n"

        echo "$DEFAULT_SERVICE" > "$DIR/default_service"

        #
        # Build docker-compose.yml
        #

        printf "Building docker-compose.yml..."

        cp "$BLUEPRINT_DIR"/templates/docker-compose.yml "$PWD/docker-compose.yml"
        
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

        docker-compose build ${BUILD_ARGS[@]}

        docker-compose up -d

        #
        # Synchronize container users with current host user during development
        #

        if [[ -n "$SYNC_USER" ]]; then
            echo "Synchronizing user '$SYNC_USER'..."
            docker-compose exec "$DEFAULT_SERVICE" usermod -u "$UID" "$SYNC_USER"
            docker-compose exec "$DEFAULT_SERVICE" groupmod -g "$GID" "$SYNC_USER"
        
            HOME_DIR="$(docker-compose exec --user="$UID":"$GID" "$DEFAULT_SERVICE" env | grep '^HOME=' | sed -r 's/^HOME=(.*)/\1/' | sed 's/\r//' | sed 's/\n//')"

            echo "Chowning home directory '$HOME_DIR'..."

            docker-compose exec "$DEFAULT_SERVICE" chown -R "$UID":"$GID" "$HOME_DIR"
        fi

        if [[ -n "$MAKE_DIRS" ]]; then
            if [[ -z "$SYNC_USER" ]]; then
                docker-compose exec "$DEFAULT_SERVICE" mkdir -p "${MAKE_DIRS[@]}"
            else
                docker-compose exec --user="$UID":"$GID" "$DEFAULT_SERVICE" mkdir -p "${MAKE_DIRS[@]}"
            fi
        fi

        for command in "${POSTBUILD_COMMANDS[@]}"; do
            echo "Running '$command'..."
            if [[ -z "$SYNC_USER" ]]; then
                docker-compose exec "$DEFAULT_SERVICE" $command
            else
                docker-compose exec --user="$UID":"$GID" "$DEFAULT_SERVICE" $command
            fi
        done

        #
        # Restart container to apply chown
        #

        echo "Restarting container '$DEFAULT_SERVICE'..."
        docker-compose restart "$DEFAULT_SERVICE"
        
        #
        # Run environment initialization
        #
        
        if [[ -d "$ENV_DIR" ]] && [[ -f "$ENV_DIR/init.sh" ]]; then
            echo "Initializing environment..."
            bash "$ENV_DIR/init.sh"
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

        ;;

    exec)
        docker-compose exec --user="$UID":"$GID" ${@:2}
        ;;


    up|down|restart)
        docker-compose "$1" ${@:2}
        ;;
    
    default)
        if [[ -z "$2" ]]; then
            if [[ -z "$DEFAULT_SERVICE" ]]; then
                echo "No default service set"
            else
                echo "Current default service: $DEFAULT_SERVICE"
            fi
            echo ""
            echo "Usage: $EXECUTABLE_NAME default <service>"
        else
            if [[ "$2" == "clear" ]]; then
                if [[ -f $DIR/default_service ]]; then
                    rm $DIR/default_service
                fi
                echo "Default service cleared"
            else
                SERVICES=$(docker-compose ps --services)
                if [[ ${SERVICES[@]} =~ $2 ]]; then
                    echo "$2" > $DIR/default_service
                    init_default_service
                    echo "Default service set: $2"
                else
                    echo "Unknown service '$2'."
                    echo "Available services:" "$SERVICES"
                fi
            fi
        fi
        ;;
    
    -h | --help)
        source ./commands/help.sh
        ;;
    
    *)
        if [[ ! -z "$1" ]]; then
            if [[ ! -z "$2" ]] && [[ "$2" == "sudo" ]]; then
                COMMAND="docker-compose exec $1 ${@:3}"
            elif [[ "$1" == "sudo" ]]; then
                COMMAND="docker-compose exec $DEFAULT_SERVICE ${@:2}"
            else
                COMMAND="docker-compose exec --user=$UID:$GID $DEFAULT_SERVICE $@"
            fi

            if [[ -z "$DEFAULT_SERVICE" ]]; then
                echo "Cannot execute command against default service - no default service specified."
                exit 1
            else
                $COMMAND
            fi
        else
            source ./commands/help.sh
        fi
        ;;
esac
