#!/bin/bash

shopt -s dotglob

readonly BLADE_VERSION=${BLADE_VERSION:-"3.9.1"}

readonly GRADLE_LCP_IMAGE_7_0=${GRADLE_LCP_IMAGE_7_0:-"liferay/dxp:7.0.10-sp13"}
readonly GRADLE_LCP_IMAGE_7_1=${GRADLE_LCP_IMAGE_7_1:-"liferay/dxp:7.1.10-dxp-16"}
readonly GRADLE_LCP_IMAGE_7_2=${GRADLE_LCP_IMAGE_7_2:-"liferay/dxp:7.2.10-dxp-4"}

readonly LIFERAY_LCP_IMAGE_7_0=${LIFERAY_LCP_IMAGE_7_0:-"liferaycloud/liferay-dxp:7.0-4.0.0-beta.1"}
readonly LIFERAY_LCP_IMAGE_7_1=${LIFERAY_LCP_IMAGE_7_1:-"liferaycloud/liferay-dxp:7.1-4.0.0-beta.1"}
readonly LIFERAY_LCP_IMAGE_7_2=${LIFERAY_LCP_IMAGE_7_2:-"liferaycloud/liferay-dxp:7.2-4.0.0-beta.1"}

readonly SEARCH_LCP_IMAGE_2=${SEARCH_LCP_IMAGE_2:-"liferaycloud/elasticsearch:2.4.6-4.0.0-beta.1"}
readonly SEARCH_LCP_IMAGE_6=${SEARCH_LCP_IMAGE_6:-"liferaycloud/elasticsearch:6.8.6-4.0.0-beta.1"}

readonly BACKUP_LCP_IMAGE=${BACKUP_LCP_IMAGE:-"liferaycloud/backup:4.0.0-beta.1"}
readonly DATABASE_LCP_IMAGE=${DATABASE_LCP_IMAGE:-"liferaycloud/database:4.0.0-beta.1"}
readonly CI_LCP_IMAGE=${CI_LCP_IMAGE:-"liferaycloud/jenkins:2.190.1-4.0.0-beta.2"}
readonly WEBSERVER_LCP_IMAGE=${WEBSERVER_LCP_IMAGE:-"liferaycloud/nginx:1.16.1-4.0.0-beta.1"}

if [[ "$OSTYPE" == "darwin"* ]]; then
  readonly SED_ARGS='-i ""'
else
  readonly SED_ARGS='-i'
fi

main() {
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

  if [ ! $CURL ] && [ ! $WGET ]; then
    echo >&2 "This script requires curl or wget to be installed"
  fi

  printOpeningInstructions

  promptForLiferayVersion
  promptForEnvironments
  promptForESPlugins

  if ! grep "upgrade-workspace" .gitignore &>/dev/null; then
    printf '\nupgrade-workspace.sh' >>.gitignore
    git add .gitignore && git commit -m 'Add upgrade script to .gitignore'
  fi

  git checkout -b upgrade-workspace

  upgradeBackupService
  upgradeCiService
  upgradeDatabaseService
  upgradeSearchService
  upgradeLiferayService
  upgradeWebserverService

  cleanupObsoleteFiles
}

printOpeningInstructions() {
  printf "\n### DXP Cloud Project Workspace Upgrade ###\n\n"
  printf "The script creates a commit on the current branch that adds itself to .gitignore.\n"
  printf "Next, a new branch called 'upgrade-workspace' is checked out, and all the changes for each service are committed separately.\n"
  printf "The workspace upgrade assumes a clean working branch, and that wget and java are installed.\n"
  printf "After the upgrade has run, you can completely undo and rerun it with the following commands:\n\n"
  printf "\tgit checkout <original-branch-name> && git reset --hard && git branch -D upgrade-workspace; ./upgrade-workspace.sh\n\n"

  read -rs -p "Press enter to continue: "
}

promptForLiferayVersion() {
  printf "\n"
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

promptForEnvironments() {
  printf '\nPlease enter a comma-delimited list of the different environments in your project, apart from the "common" environment.'
  printf '\nFor example, you can write "dev,prd". This script will only copy files from these environments and the common environment.'
  printf '\nTaking the webserver service as an example, if you enter "dev", files will be copied from lcp/webserver/config/dev to webserver/configs/dev/conf.d.'
  printf '\nHowever, files in lcp/webserver/config/anotherenv would be ignored and deleted.\n\n'

  IFS=',' read -p 'Please enter a comma-delimited list of environments: ' -ra ENVIRONMENTS

  ENVIRONMENTS=("common" "${ENVIRONMENTS[@]}")

  printf "\nThis script will create an environment folder in each service for the following environments:\n"

  for i in "${ENVIRONMENTS[@]}"; do
    echo "$i"
  done
}

promptForESPlugins() {
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
}

upgradeBackupService() {
  printf "\n### Upgrading backup service folder structure ###\n\n"

  mkdir backup

  mv lcp/backup/* backup/

  replaceImage backup "${BACKUP_LCP_IMAGE}"

  for i in "${ENVIRONMENTS[@]}"; do
    mkdir -p backup/configs/"$i"/scripts
    touch backup/configs/"$i"/scripts/.keep

    mv backup/script/"$i"/* backup/configs/"$i"/scripts
  done

  rm -rf backup/script

  git add --all && git commit -m 'Upgrade backup service folder structure'
}

upgradeDatabaseService() {
  printf "\n ### Upgrading database service folder structure ###\n\n"

  mkdir database

  mv lcp/database/* database/

  replaceImage database "${DATABASE_LCP_IMAGE}"

  git add --all && git commit -m 'Upgrade database service folder structure'
}

upgradeCiService() {
  printf "\n ### Upgrading ci service folder structure ###\n\n"

  mkdir ci

  mv lcp/ci/* ci/

  replaceImage ci "${CI_LCP_IMAGE}"

  echo 'Moving Jenkinsfile to ci dir and commenting it out so that default Jenkinsfile provided by the Jenkins service is used'

  mv Jenkinsfile ci/#Jenkinsfile

  touch 'ci/#Jenkinsfile-after-all' 'ci/#Jenkinsfile-before-all' 'ci/#Jenkinsfile-before-cloud-build' 'ci/#Jenkinsfile-before-cloud-deploy' 'ci/#Jenkinsfile-post-always'

  git add --all && git commit -m 'Upgrade ci service folder structure'
}

upgradeSearchService() {
  printf "\n### Upgrading search service folder structure ###\n\n"

  mkdir search

  mv lcp/search/* search/

  SEARCH_LCP_IMAGE=${SEARCH_LCP_IMAGE_6}

  if [ "$DXP_VERSION" = "7.0" ]; then
    SEARCH_LCP_IMAGE=${SEARCH_LCP_IMAGE_2}
  fi

  replaceImage search "${SEARCH_LCP_IMAGE}"

  for i in "${ENVIRONMENTS[@]}"; do
    mkdir -p search/configs/"$i"/config
    touch search/configs/"$i"/config/.keep
    mkdir -p search/configs/"$i"/license
    touch search/configs/"$i"/license/.keep
    mkdir -p search/configs/"$i"/scripts
    touch search/configs/"$i"/scripts/.keep

    mv search/config/"$i"/* search/configs/"$i"/config
    mv search/license/"$i"/* search/configs/"$i"/license
    mv search/script/"$i"/* search/configs/"$i"/scripts
  done

  rm -rf search/config search/deploy search/license search/script

  [[ -n "$ES_PLUGINS" ]] && sed $SED_ARGS "s/\(\\w*\"env\": {\)/\1\n    \"LCP_SERVICE_SEARCH_ES_PLUGINS\": \"${ES_PLUGINS}\",/" search/LCP.json

  git add --all && git commit -m 'Upgrade search service folder structure'
}

upgradeLiferayService() {
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

  for i in "${ENVIRONMENTS[@]}"; do
    mkdir -p liferay/configs/"$i"/osgi/configs
    touch liferay/configs/"$i"/osgi/configs/.keep
    mkdir -p liferay/configs/"$i"/deploy
    touch liferay/configs/"$i"/deploy/.keep
    mkdir -p liferay/configs/"$i"/scripts
    touch liferay/configs/"$i"/scripts/.keep
    mkdir -p liferay/configs/"$i"/patching
    touch liferay/configs/"$i"/patching/.keep

    mv liferay/config/"$i"/portal-*.properties liferay/configs/"$i"
    [[ "$i" != common ]] && echo "include-and-override=portal-all.properties
include-and-override=portal-env.properties" >liferay/configs/"$i"/portal-ext.properties

    mv liferay/config/"$i"/*.config liferay/configs/"$i"/osgi/configs
    mv liferay/config/"$i"/*.cfg liferay/configs/"$i"/osgi/configs
    mv liferay/deploy/"$i"/* liferay/configs/"$i"/deploy
    mv liferay/script/"$i"/* liferay/configs/"$i"/scripts
    mv liferay/hotfix/"$i"/* liferay/configs/"$i"/patching
    mv liferay/license/"$i"/* liferay/configs/"$i"/deploy
  done

  rm -rf liferay/config liferay/deploy liferay/script liferay/hotfix liferay/license

  rm -rf liferay/configs/prod

  sed $SED_ARGS '/liferay\.workspace\.docker\.image\.liferay/s/^\s*#//' liferay/gradle.properties
  sed $SED_ARGS "s|\(liferay\.workspace\.docker\.image\.liferay=\).*\$|\1${GRADLE_LCP_IMAGE}|" liferay/gradle.properties
  sed $SED_ARGS 's/2\.2\.[0-9]\+/2\.2\.11/' liferay/settings.gradle

  git add --all && git commit -m 'Upgrade liferay service folder structure'
}

upgradeWebserverService() {
  printf "\n### Upgrading webserver service folder structure ###\n\n"

  mkdir webserver

  mv lcp/webserver/* webserver/

  replaceImage webserver "${WEBSERVER_LCP_IMAGE}"

  for i in "${ENVIRONMENTS[@]}"; do
    mkdir -p webserver/configs/"$i"/conf.d
    touch webserver/configs/"$i"/conf.d/.keep
    mkdir -p webserver/configs/"$i"/public
    touch webserver/configs/"$i"/public/.keep
    mkdir -p webserver/configs/"$i"/scripts
    touch webserver/configs/"$i"/scripts/.keep

    mv webserver/config/"$i"/* webserver/configs/"$i"/conf.d
    mv webserver/deploy/"$i"/* webserver/configs/"$i"/public
    mv webserver/script/"$i"/* webserver/configs/"$i"/scripts
  done

  rm -rf webserver/config webserver/deploy webserver/script

  git add --all && git commit -m 'Upgrade webserver service folder structure'
}

cleanupObsoleteFiles() {
  printf '\n### Deleting obsolete files in the root directory ### \n\n'

  rm -rf \
    README-dxpcloud.md \
    README.md

  rm -rf lcp

  git add --all && git commit -m 'Delete obsolete files in the root directory'
}

main
