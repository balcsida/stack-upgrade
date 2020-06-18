#!/bin/bash

shopt -s dotglob

readonly BLADE_VERSION=${BLADE_VERSION:-"3.9.2"}

readonly GRADLE_LCP_IMAGE_7_0=${GRADLE_LCP_IMAGE_7_0:-"liferay/dxp:7.0.10-sp13-202003272332"}
readonly GRADLE_LCP_IMAGE_7_1=${GRADLE_LCP_IMAGE_7_1:-"liferay/dxp:7.1.10-sp4-202004031130"}
readonly GRADLE_LCP_IMAGE_7_2=${GRADLE_LCP_IMAGE_7_2:-"liferay/dxp:7.2.10-sp2-202005120922"}

readonly LIFERAY_LCP_IMAGE_7_0=${LIFERAY_LCP_IMAGE_7_0:-"liferaycloud/liferay-dxp:7.0-4.0.0"}
readonly LIFERAY_LCP_IMAGE_7_1=${LIFERAY_LCP_IMAGE_7_1:-"liferaycloud/liferay-dxp:7.1-4.0.0"}
readonly LIFERAY_LCP_IMAGE_7_2=${LIFERAY_LCP_IMAGE_7_2:-"liferaycloud/liferay-dxp:7.2-4.0.0"}

readonly SEARCH_LCP_IMAGE_2=${SEARCH_LCP_IMAGE_2:-"liferaycloud/elasticsearch:2.4.6-4.0.0"}
readonly SEARCH_LCP_IMAGE_6=${SEARCH_LCP_IMAGE_6:-"liferaycloud/elasticsearch:6.8.6-4.0.0"}

readonly BACKUP_LCP_IMAGE=${BACKUP_LCP_IMAGE:-"liferaycloud/backup:4.0.0"}
readonly DATABASE_LCP_IMAGE=${DATABASE_LCP_IMAGE:-"liferaycloud/database:4.0.0"}
readonly CI_LCP_IMAGE=${CI_LCP_IMAGE:-"liferaycloud/jenkins:2.222.1-4.0.0"}
readonly WEBSERVER_LCP_IMAGE=${WEBSERVER_LCP_IMAGE:-"liferaycloud/nginx:1.16.1-4.0.0"}

if [[ "$OSTYPE" == "darwin"* ]]; then
  readonly SED_ARGS='-i .wksbck'
else
  readonly SED_ARGS='-i'
fi

readonly API_URL=https://api.liferay.cloud
readonly LOGIN_URL=${API_URL}/login
readonly PROJECTS_URL=${API_URL}/projects

main() {
  validate_program_installation

  print_opening_instructions

  prompt_for_database_secret_variables
  prompt_for_liferay_version
  prompt_for_environments
  prompt_for_elasticsearch_plugins

  create_database_secrets

  checkout_upgrade_workspace_branch

  upgrade_backup_service
  upgrade_ci_service
  upgrade_database_service
  upgrade_search_service
  upgrade_liferay_service
  upgrade_webserver_service

  cleanup_obsolete_files
}

checkout_upgrade_workspace_branch() {
  if ! grep "upgrade-workspace" .gitignore &>/dev/null; then
    printf '\nupgrade-workspace.sh' >>.gitignore
    git add .gitignore && git commit -m 'Add upgrade script to .gitignore'
  fi

  git checkout -b upgrade-workspace
}

prompt_for_database_secret_variables() {
  printf "\n"
  read -p "Please enter your project id: " -r PROJECT_ID

  lcp logout
  echo 'Please login to DXP Cloud Console'
  lcp login

  LCP_CONFIG_FILE=$HOME/.lcp

  if [[ -f "$LCP_CONFIG_FILE" ]]; then
    echo "$LCP_CONFIG_FILE exists"
  else
    echo "$LCP_CONFIG_FILE does not exist!"
    exit 1
  fi

  TOKEN=$(grep -A 2 "infrastructure=liferay.cloud" "$LCP_CONFIG_FILE" | awk -F "=" '/token/ {print $2}')

  readonly PORTAL_ALL_PROPERTIES_LOCATION=lcp/liferay/config/common/portal-all.properties

  DATABASE_PASSWORD=$(grep "jdbc.default.password" "${PORTAL_ALL_PROPERTIES_LOCATION}" | cut -d '=' -f 2)

  [[ -z "${DATABASE_PASSWORD}" ]] &&
    read -p "Could not find jdbc.default.password in ${PORTAL_ALL_PROPERTIES_LOCATION}. Please enter your database password: " -r DATABASE_PASSWORD
}

validate_program_installation() {
  if ! git status &>/dev/null; then
    echo >&2 "This script must be run from a git repository"

    exit
  fi

  if ! java -version &>/dev/null; then
    echo >&2 "This script requires java to be installed"

    exit
  fi

  if ! curl --version &>/dev/null; then
    CURL=false
  fi

  if ! wget --version &>/dev/null; then
    WGET=false
  fi

  if [[ $CURL == false ]] && [[ $WGET == false ]]; then
    echo >&2 "This script requires curl or wget to be installed"

    exit
  fi

  if ! lcp version &>/dev/null; then
    echo >&2 "This script requires lcp to be installed"

    exit
  fi
}

create_database_secrets() {
  for env in "${ENVIRONMENTS[@]}"; do
    [[ "$env" == common ]] && continue

    local secrets
    local env_id="${PROJECT_ID}-${env}"

    if [ "$WGET" != false ]; then
      secrets=$(
        wget "${PROJECTS_URL}/${env_id}/secrets" \
          --header="Authorization: Bearer ${TOKEN}" \
          --header='content-type: application/x-www-form-urlencoded' \
          --auth-no-challenge \
          -O -
      )
    else
      secrets=$(
        curl "${PROJECTS_URL}/${env_id}/secrets" \
          -X GET \
          -H "Authorization: Bearer ${TOKEN}"
      )
    fi

    create_secret "${env_id}" "${secrets}" 'lcp-secret-database-name' 'lportal'
    create_secret "${env_id}" "${secrets}" 'lcp-secret-database-user' 'dxpcloud'
    create_secret "${env_id}" "${secrets}" 'lcp-secret-database-password' "${DATABASE_PASSWORD}"
  done
}

create_secret() {
  local env_id="${1}"
  local secrets="${2}"
  local secret_name="${3}"
  local secret_value="${4}"

  if echo "${secrets}" | grep "${secret_name}" &>/dev/null; then
    echo "The secret '${secret_name}' already exists, skipping secret creation"

    return
  fi

  echo "creating secret for ${env_id} ${secret_name}=${secret_value}"

  if [ "$WGET" != false ]; then
    wget "${PROJECTS_URL}/${env_id}/secrets" \
      --header="Authorization: Bearer ${TOKEN}" \
      --header='content-type: application/x-www-form-urlencoded' \
      --auth-no-challenge \
      --post-data="name=${secret_name}&value=${secret_value}"
  else
    curl "${PROJECTS_URL}/${env_id}/secrets" \
      -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/json; charset=utf-8' \
      -d $'{
        "name": "'"${secret_name}"'",
        "value": "'"${secret_value}"'"
      }'
  fi
}

print_opening_instructions() {
  printf "\n### DXP Cloud Project Workspace Upgrade ###\n\n"
  printf "The script creates a commit on the current branch that adds itself to .gitignore.\n"
  printf "Next, a new branch called 'upgrade-workspace' is checked out, and all the changes for each service are committed separately.\n"
  printf "The workspace upgrade assumes a clean working branch, and that wget/curl, java, and lcp are installed.\n"
  printf "After the upgrade has run, you can completely undo and rerun it with the following commands:\n\n"
  printf "\tgit checkout <original-branch-name> && git reset --hard && git branch -D upgrade-workspace; ./upgrade-workspace.sh\n\n"

  read -rs -p "Press enter to continue: "
}

prompt_for_liferay_version() {
  printf "\n"

  PS3='Please select the Liferay DXP version, which will determine the Liferay CLOUD image set in liferay/LCP.json and the Liferay image set in liferay/gradle.properties: '
  options=("7.0" "7.1" "7.2")
  select opt in "${options[@]}"; do
    DXP_VERSION=$opt
    case $opt in
    7.0)
      GRADLE_LCP_IMAGE=${GRADLE_LCP_IMAGE_7_0}
      LIFERAY_LCP_IMAGE=${LIFERAY_LCP_IMAGE_7_0}
      break
      ;;
    7.1)
      GRADLE_LCP_IMAGE=${GRADLE_LCP_IMAGE_7_1}
      LIFERAY_LCP_IMAGE=${LIFERAY_LCP_IMAGE_7_1}
      break
      ;;
    7.2)
      GRADLE_LCP_IMAGE=${GRADLE_LCP_IMAGE_7_2}
      LIFERAY_LCP_IMAGE=${LIFERAY_LCP_IMAGE_7_2}
      DXP_VERSION=$opt
      break
      ;;
    *) echo >&2 "Invalid selection; please select 1..3" ;;
    esac
  done

  echo "Using Liferay DXP version $DXP_VERSION"
  echo ""
  echo "The image in liferay/LCP.json will be set to $LIFERAY_LCP_IMAGE"
  echo "The image in liferay/gradle.properties will be set to $GRADLE_LCP_IMAGE"
}

prompt_for_environments() {
  printf '\nPlease enter a comma-delimited list of the different environments in your project, apart from the "common" environment.'
  printf '\nFor example, you can write "dev,prd". This script will only copy files from these environments and the common environment.'
  printf '\nTaking the webserver service as an example, if you enter "dev", files will be copied from lcp/webserver/config/dev to webserver/configs/dev/conf.d.'
  printf '\nHowever, files in lcp/webserver/config/anotherenv would be ignored and deleted.\n\n'

  IFS=',' read -p 'Please enter a comma-delimited list of environments: ' -ra ENVIRONMENTS

  ENVIRONMENTS=("common" "${ENVIRONMENTS[@]}")

  printf "\nThis script will create an environment folder in each service for the following environments:\n"

  for env in "${ENVIRONMENTS[@]}"; do
    echo "$env"
  done
}

prompt_for_elasticsearch_plugins() {
  printf '\nPlease enter a comma-delimited list of elasticsearch plugins you would like to install, if any.'
  printf '\nThis script will create an ENV var called LCP_SERVICE_SEARCH_ES_PLUGINS in search/LCP.json with the value that you set.'
  printf '\nIf you want, you can easily do this later, and you can set LCP_SERVICE_SEARCH_ES_PLUGINS per environment as well.'
  printf '\nThis script sets LCP_SERVICE_SEARCH_ES_PLUGINS globally for all environments.\n'

  read -p 'Please enter a comma-delimited list of elasticsearch plugins: ' -r ES_PLUGINS

  if [[ -n $ES_PLUGINS ]]; then
    echo "Will set LCP_SERVICE_SEARCH_ES_PLUGINS=$ES_PLUGINS in LCP.json"
  else
    echo "No plugins will be set in LCP.json"
  fi
}

replaceImage() {
  echo "Setting image in $1/LCP.json to $2"

  sed $SED_ARGS "s|\(\\w*\"image\": \).*\$|\1\"${2}\",|" "$1"/LCP.json

  [[ -f "$1"/LCP.json.wksbck ]] && rm "$1"/LCP.json.wksbck
}

upgrade_backup_service() {
  printf "\n### Upgrading backup service folder structure ###\n\n"

  mkdir backup

  mv lcp/backup/* backup/

  replaceImage backup "${BACKUP_LCP_IMAGE}"

  for env in "${ENVIRONMENTS[@]}"; do
    mkdir -p backup/configs/"$env"/scripts
    touch backup/configs/"$env"/scripts/.keep

    mv backup/script/"$env"/* backup/configs/"$env"/scripts
  done

  rm -rf backup/script

  git add --all && git commit -m 'Upgrade backup service folder structure'
}

upgrade_database_service() {
  printf "\n ### Upgrading database service folder structure ###\n\n"

  mkdir database

  mv lcp/database/* database/

  replaceImage database "${DATABASE_LCP_IMAGE}"

  git add --all && git commit -m 'Upgrade database service folder structure'
}

upgrade_ci_service() {
  printf "\n ### Upgrading ci service folder structure ###\n\n"

  mkdir ci

  mv lcp/ci/* ci/

  replaceImage ci "${CI_LCP_IMAGE}"

  echo 'Moving Jenkinsfile to ci dir and commenting it out so that default Jenkinsfile provided by the Jenkins service is used'

  mv Jenkinsfile ci/#Jenkinsfile

  touch 'ci/#Jenkinsfile-after-all' 'ci/#Jenkinsfile-before-all' 'ci/#Jenkinsfile-before-cloud-build' 'ci/#Jenkinsfile-before-cloud-deploy' 'ci/#Jenkinsfile-post-always'

  git add --all && git commit -m 'Upgrade ci service folder structure'
}

upgrade_search_service() {
  printf "\n### Upgrading search service folder structure ###\n\n"

  mkdir search

  mv lcp/search/* search/

  SEARCH_LCP_IMAGE=${SEARCH_LCP_IMAGE_6}

  if [ "$DXP_VERSION" = "7.0" ]; then
    SEARCH_LCP_IMAGE=${SEARCH_LCP_IMAGE_2}
  fi

  replaceImage search "${SEARCH_LCP_IMAGE}"

  for env in "${ENVIRONMENTS[@]}"; do
    mkdir -p search/configs/"$env"/config
    touch search/configs/"$env"/config/.keep
    mkdir -p search/configs/"$env"/license
    touch search/configs/"$env"/license/.keep
    mkdir -p search/configs/"$env"/scripts
    touch search/configs/"$env"/scripts/.keep

    mv search/config/"$env"/* search/configs/"$env"/config
    mv search/license/"$env"/* search/configs/"$env"/license
    mv search/script/"$env"/* search/configs/"$env"/scripts
  done

  rm -rf search/config search/deploy search/license search/script

  [[ -n "$ES_PLUGINS" ]] && sed $SED_ARGS "s/\(\\w*\"env\": {\)/\1\n    \"LCP_SERVICE_SEARCH_ES_PLUGINS\": \"${ES_PLUGINS}\",/" search/LCP.json

  [[ -f search/LCP.json.wksbck ]] && rm search/LCP.json.wksbck

  git add --all && git commit -m 'Upgrade search service folder structure'
}

upgrade_liferay_service() {
  printf "\n### Upgrading liferay service folder structure ###\n\n"

  echo "Deleting obsolete files in git repo root related to the Liferay service..."

  rm -rf \
    build.gradle \
    gradle.properties \
    gradlew \
    gradlew.bat \
    settings.gradle \
    gradle \
    .gradle

  if [ "$WGET" != false ]; then
    wget -O blade.jar https://repo1.maven.org/maven2/com/liferay/blade/com.liferay.blade.cli/${BLADE_VERSION}/com.liferay.blade.cli-${BLADE_VERSION}.jar
  else
    curl --output blade.jar https://repo1.maven.org/maven2/com/liferay/blade/com.liferay.blade.cli/${BLADE_VERSION}/com.liferay.blade.cli-${BLADE_VERSION}.jar
  fi

  rm -rf liferay/*

  java -jar blade.jar init -v ${DXP_VERSION} liferay

  rm blade.jar

  mv lcp/liferay/* liferay/

  replaceImage liferay "${LIFERAY_LCP_IMAGE}"

  mv modules liferay/
  mv themes liferay/
  mv wars liferay/

  for env in "${ENVIRONMENTS[@]}"; do
    mkdir -p liferay/configs/"$env"/osgi/configs
    touch liferay/configs/"$env"/osgi/configs/.keep
    mkdir -p liferay/configs/"$env"/deploy
    touch liferay/configs/"$env"/deploy/.keep
    mkdir -p liferay/configs/"$env"/scripts
    touch liferay/configs/"$env"/scripts/.keep
    mkdir -p liferay/configs/"$env"/patching
    touch liferay/configs/"$env"/patching/.keep

    mv liferay/config/"$env"/portal-*.properties liferay/configs/"$env"
    [[ "$env" != common ]] && echo "include-and-override=portal-all.properties
include-and-override=portal-env.properties" >liferay/configs/"$env"/portal-ext.properties

    mv liferay/config/"$env"/*.config liferay/configs/"$env"/osgi/configs
    mv liferay/config/"$env"/*.cfg liferay/configs/"$env"/osgi/configs
    mv liferay/deploy/"$env"/* liferay/configs/"$env"/deploy
    mv liferay/script/"$env"/* liferay/configs/"$env"/scripts
    mv liferay/hotfix/"$env"/* liferay/configs/"$env"/patching
    mv liferay/license/"$env"/* liferay/configs/"$env"/deploy
  done

  rm -rf liferay/config liferay/deploy liferay/script liferay/hotfix liferay/license

  rm -rf liferay/configs/prod

  sed $SED_ARGS "s|\(liferay\.workspace\.docker\.image\.liferay=\).*\$|\1${GRADLE_LCP_IMAGE}|" liferay/gradle.properties
  sed $SED_ARGS "s|\#liferay\.workspace\.docker\.image\.liferay=|liferay\.workspace\.docker\.image\.liferay=|" liferay/portal-test.properties

  [[ -f liferay/gradle.properties.wksbck ]] && rm liferay/gradle.properties.wksbck

  git add --all && git commit -m 'Upgrade liferay service folder structure'
}

upgrade_webserver_service() {
  printf "\n### Upgrading webserver service folder structure ###\n\n"

  mkdir webserver

  mv lcp/webserver/* webserver/

  replaceImage webserver "${WEBSERVER_LCP_IMAGE}"

  for env in "${ENVIRONMENTS[@]}"; do
    mkdir -p webserver/configs/"$env"/conf.d
    touch webserver/configs/"$env"/conf.d/.keep
    mkdir -p webserver/configs/"$env"/public
    touch webserver/configs/"$env"/public/.keep
    mkdir -p webserver/configs/"$env"/scripts
    touch webserver/configs/"$env"/scripts/.keep

    mv webserver/config/"$env"/* webserver/configs/"$env"/conf.d
    mv webserver/deploy/"$env"/* webserver/configs/"$env"/public
    mv webserver/script/"$env"/* webserver/configs/"$env"/scripts
  done

  rm -rf webserver/config webserver/deploy webserver/script

  git add --all && git commit -m 'Upgrade webserver service folder structure'
}

cleanup_obsolete_files() {
  printf '\n### Deleting obsolete files in the root directory ### \n\n'

  rm -rf \
    README-dxpcloud.md \
    README.md

  rm -rf lcp

  git add --all && git commit -m 'Delete obsolete files in the root directory'
}

main
