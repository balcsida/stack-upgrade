# Upgrading Your Git Repository

First, use the `upgrade-script.sh` that can be run to update your Git repo to
the new structure.

The script, apart from deleting and copying files, will set the images tags for
each service to 4.0.0. In order for the services to be compatible with the new
folder structure, 4.x images must be used.

Once, you made those changes locally, you're ready to deploy to your development
environment.

# Deploy using the CLI

In this new structure, the image version is declared into the `LCP.json` of each
service instead of the `gradle.properties` file. Typically if you want to deploy
one service, you can navigate to the service and run `lcp deploy`. For example,
`cd webserver && lcp deploy`. Things work slightly different for the liferay
service because it needs to be built first. Use the following command to deploy
Liferay:

```
cd liferay
./gradlew clean deploy createDockerfile
cp LCP.json build/docker
cd build/docker
lcp deploy
```

# Backup Service

## File Overrides

### Custom Scripts

Place custom `.sql` scripts into `backup/configs/{ENV}/scripts`. All `.sql`
scripts will be copied into the backup service container. You can also compress
large `.sql` files in the `.tgz`, `.gz`, or `.zip` format and place them in the
`scripts` directory. You can include multiple `.sql` files in a single
compressed file.

The `.sql` scripts are executed after a backup restore process is finished. For
example, when restoring from `prd` to `dev`, the `dev` service is responsible
for actually doing the restore. Therefore, if you want to truncate certain
tables on the `dev` environment, then you could add them to
`backup/configs/dev/scripts`, and they would be executing only when restoring to
the `dev` environment.

# CI Service

## Default Jenkinsfile Extension Points

If you are an existing customer who ran the script to update the folder
structure of your Git repository, you will notice that the script copies the
`Jenkinsfile` at the root of your repository to `ci/#Jenkinsfile`, commenting it
out. It is commented out because the Jenkins 4.0.0 image now contains a default
pipeline, so having a Jenkinsfile in you Git repository is no longer required.
It is moved to the `ci` directory because that is the new default location for
the Jenkinsfile, in case you decide to opt out of using the default Jenkinsfile.

In addition the upgrade script adds four files to the `ci` folder. New customers
will have these files provisioned by default:

- `ci/#Jenkinsfile-before-project-build`
- `ci/#Jenkinsfile-before-cloud-build`
- `ci/#Jenkinsfile-before-cloud-deploy`
- `ci/#Jenkinsfile-post-always`

These are commented out initially, but are included to show the different
extension points. To see how they are used in the default pipeline, simply
monitor the Jenkins service startup logs. The full default Jenkinsfile is
printed out in the startup logs. In addition, the logs print out whether Jenkins
is configured to use the default Jenkinsfile or a custom Jenkinsfile in your Git
repository.

Here is a basic overview of the steps in the ci build process:

1. Load `ci/Jenkinsfile-before-project-build`, if it exists.
2. Build all the services in the project.
3. Load `ci/Jenkinsfile-before-cloud-build`, if it exists.
4. Create the DXP Cloud build that you see in console.
5. Load `ci/Jenkinsfile-before-cloud-deploy`, if it exists.
6. Optionally deploy the build to an environment in the cloud, depending on if
   the current branch has been specified as the deploy branch. This is
   configured through the `DEPLOY_BRANCH` environment variable. The
   `DEPLOY_TARGET` environment variable specifies which environment to deploy
   to.
7. Load `ci/Jenkinsfile-post-always`, if it exists. This will run both when the
   build fails and when it succeeds.

You will likely want a way to share code between these extension points. One
basic way is to load a groovy script. For example, you could create a groovy
file called `ci/util.groovy` with these contents:

```
def sendSlackMessage(message) {
	println(message)
}

return this
```

Then you could insert the following in `ci/Jenkinsfile-before-cloud-build`:

```
def util = load("ci/util.groovy")

util.sendSlackMessage("About to create DXP Cloud build...")
```

## Default Jenkinsfile Environment Variables

The following environment variables are only used in the default Jenkinsfile.
They are listed along with their default values. Although these environment
variables are specific to Liferay, they correspond directly to Jenkins pipeline
options. To see what they do please refer to
[Jenkins documentation regarding pipeline options](https://jenkins.io/doc/book/pipeline/syntax/#options);

```
LCP_CI_BUILD_TIMEOUT_MINUTES
LCP_CI_PRESERVE_STASHES_BUILD_COUNT
LCP_CI_BUILD_NUM_TO_KEEP
LCP_CI_BUILD_DAYS_TO_KEEP
LCP_CI_ARTIFACT_NUM_TO_KEEP
LCP_CI_ARTIFACT_DAYS_TO_KEEP
```

## Using a Jenkinsfile in Your Git Repository

If using the default Jenkinsfile with its extension points does not meet your
needs, please start by creating a feature request. Otherwise, you can opt out of
using the default Jenkinsfile by setting the `LCP_CI_USE_DEFAULT_JENKINSFILE`
environment variable to `false`. By default this environment variable is set to
`true`. Create the custom Jenkinsfile in the `ci` folder in order for it to be
read. Alternatively, set the `LCP_CI_SCM_JENKINSFILE_PATH` environment variable
to the path you desire, relative to the Git repository root.

You can use the default Jenkinsfile as a guideline when writing a custom
Jenkinsfile. You will notice that in the 4.0.0 Liferay Jenkins image, the
different stages have been encapsulated into a Jenkins plugin which provides an
API, such that the default Jenkinsfile has been trimmed down considerably.

# Liferay Service

## Liferay DXP Cloud Image

The 4.x Liferay DXP Cloud image uses the
[Liferay DXP image](https://hub.docker.com/r/liferay/dxp) as its base image. The
source code is located [here](https://github.com/liferay/liferay-docker).

The Liferay DXP Cloud Image is referenced in `LCP.json`. You can specify the
underlying Liferay DXP image in `gradle.properties` with the
`liferay.workspace.docker.image.liferay` property. It must point to a valid
Liferay image available at https://github.com/liferay/liferay-docker. The
Liferay Cloud image and the Liferay image must match their major versions or
there will be an error when the image is built.

## File Overrides

### Liferay Workspace

The original folder structures are no longer respected in the Liferay DXP Cloud
4.x image:

- `lcp/liferay/config/{ENV}`
- `lcp/liferay/deploy/{ENV}`
- `lcp/liferay/script/{ENV}`
- `lcp/liferay/hotfix/{ENV}`
- `lcp/liferay/license/{ENV}`

Instead, in the Liferay DXP Cloud 4.x image, the `liferay` folder is a Liferay
workspace. Please refer to [Liferay workspace documentation](placeholder) for
how to develop Liferay locally using a Liferay workspace.

All configurations should now be placed in `liferay/configs/{ENV}`, which acts
as a `LIFERAY_HOME` override. For the Liferay service, there are three steps to
the override process. Look at the startup logs for details about what happens in
the three steps.

Step 1 is that our image copies defaults, which `liferay/configs/{ENV}` can
still override. Look for this in the logs:

```
##
## DXPCloud Liferay Defaults
##
```

Step 2 is that `liferay/configs/{ENV}` will override the contents of
`LIFERAY_HOME`.

Step 3 is that our image enforces certain files and configurations to be
present. This steps overrides files copied in step 2. Look for this in the logs:

```
##
## DXPCloud Liferay Overrides
##
```

### Custom Scripts

Place custom `.sh` scripts in `liferay/configs/{ENV}/scripts`.

### Hotfixes

Hotfixes and patching tools should be placed in
`liferay/configs/{ENV}/patching`.

Instead of committing large hotfix files directly to your Git repository, you
can rely on the CI service pulling in the hotfixes for you during its build
process; this approach will not work with calling `lcp deploy` from the
`liferay/build/docker` folder. To take advantage of this, you can actually add
environment variables to the CI service. The env vars should have the name
`LCP_CI_LIFERAY_DXP_HOTFIXES_{ENV}`. The value should be a comma-delimited list
of hotfixes to apply. For example, you could have the following in your
`ci/LCP.json`. Leave off the `.zip` extension from the hotfix name.

```
"env": {
   "LCP_CI_LIFERAY_DXP_HOTFIXES_COMMON": "liferay-hotfix-10-7210,liferay-hotfix-17-7210"
   "LCP_CI_LIFERAY_DXP_HOTFIXES_DEV": "liferay-hotfix-15-7210,liferay-hotfix-33-7210",
},
```

# Search Service

## File Overrides

All customizations of the search service should go in the `search/configs`
folder in your Git repository. In this folder, add new folders for
environment-specific configs, for example `prd`, `dev`, etc. _Every_ _single_
_file_ in `search/configs/common` will be copied into the
`/usr/share/elasticsearch` folder in the container running in Liferay DXP Cloud.
This copying process overwrites files and folders. After the initial copying
from `search/configs/common`, environment-specific customizations will be copied
in. For example, if the search service is being deployed in the `prd`
environment and files exist in `search/configs/prd`, those will be copied over,
potentially overriding files that were copied from `search/configs/common`.

Configurations can be included in `search/configs/{ENV}/config` because
Elasticsearch reads configs such as `elasticsearch.yml` from
`/usr/share/elasticsearch/config`. So if you create a custom `elasticsearch.yml`
in `/configs/common/config`, that will be copied to
`/usr/share/elasticsearch/config/elasticsearch.yml`, overriding the default
`elasticsearch.yml` file that the Liferay Elasticsearch service provides.

### Custom Scripts

Place custom shell scripts into `search/configs/{ENV}/scripts`. They will be
copied to `/usr/share/elasticsearch/scripts`. Any `.sh` scripts in
`/usr/share/elasticsearch/scripts` will be executed.

### Elasticsearch Licenses

An Elasticsearch `.json` license can be put in `search/configs/{ENV}/license`,
and it will be applied as part of the deployment process.

### File Overrides Summary

The main concept to grasp is that _all_ files in `search/configs/{ENV}` are
copied into `/usr/share/elasticsearch`, but only certain folders are subject to
additional processing by Liferay Cloud during service deployment. For the search
service, the only folders that are processed by Liferay code specifically are
the `license` and `scripts` folders.

## Elasticsearch Plugins

To see the installed plugins, shell into the search service and run
`bin/elasticsearch-plugin list`.

If you would like to install additional Elasticsearch plugins beyond the ones
our image installs by default, you can set the `LCP_SERVICE_SEARCH_ES_PLUGINS`
environment variable to a comma-delimited list of plugin names to be installed.
They will be installed during the service's deployment.

# Webserver Service

## File Overrides

All customizations of the webserver service should go in the `webserver/configs`
folder in your Git repository. In this folder, add new folders for
environment-specific configs, for example `prd`, `dev`, etc. _Every_ _single_
_file_ in `webserver/configs/common` will be copied into the `/etc/nginx` folder
in the container running in Liferay DXP Cloud. This copying process overwrites
files and folders. After the initial copying from `webserver/configs/common`,
environment-specific customizations will be copied in. For example, if the
webserver service is being deployed in the `prd` environment and files exist in
`webserver/configs/prd`, those will be copied over, potentially overriding files
that were copied from `webserver/configs/common`.

You can customize the root location by adding the file
`webserver/configs/{ENV}/conf.d/liferay.conf`. Make sure to name the file
`liferay.conf`; if you add a root location under a different file name, an error
will be thrown when NGINX finds two root locations, the default one that Liferay
Cloud provides plus your custom location. Shell into the webserver service and
navigate to `/etc/nginx/conf.d/liferay.conf` to see what the default
`liferay.conf` file looks like.

Other `*.conf` files can be added to `webserver/configs/{ENV}/conf.d/` to
specify additional locations.

To completely override NGINX configuration, add the file
`webserver/configs/{ENV}/nginx.conf`. At this point you are writing the
configuration of NGINX from scratch, so previous instructions about adding
`webserver/configs/{ENV}/conf.d/liferay.conf` to customize the root location and
specifying additional locations in `webserver/configs/{ENV}/conf.d/` do not
apply. Shell into the webserver service and navigate to `/etc/nginx/nginx.conf`
to see what the default `nginx.conf` file looks like.

### The Public Directory

If you wish to add custom static content, places these files in
`webserver/configs/{ENV}/public`. Liferay Cloud will look for this `public`
folder and copy all files inside of it to `/var/www/html`. You will need to add
additional locations to configure these resources. For example, add a html file
`index.html` to `webserver/configs/{ENV}/public/static` and then add a
configuration file such as `static_location.conf` to
`webserver/configs/{ENV}/conf.d` with the following content:

```
location /static/ {
  root /var/www/html;
}
```

Refer to NGINX documentation for more complex use cases.

### Custom Scripts

Place custom shell scripts into `webserver/configs/{ENV}/scripts`. They will be
copied to `/etc/nginx/scripts`. Any `.sh` scripts in `/etc/nginx/scripts` will
be executed.

### File Overrides Summary

The main concept to grasp is that _all_ files in`webserver/configs/{ENV}` are
copied into `/etc/nginx`, but only certain folders are subject to additional
processing by Liferay Cloud during service deployment. For the webserver
service, the only folders that are processed by Liferay code specifically are
the `public` and `scripts` folders.
