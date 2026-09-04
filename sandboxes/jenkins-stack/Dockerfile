# Jenkins with just enough plugins to run a Declarative Pipeline out of git.
#
# The plugin install is the only step that needs the network, and it happens
# here at build time so the lesson itself runs offline. `workflow-aggregator`
# is what `pipeline { }` is made of; `git` is what reads the Jenkinsfile.
FROM jenkins/jenkins:lts-jdk17

RUN jenkins-plugin-cli --plugins \
      workflow-aggregator \
      git \
 && rm -rf /var/jenkins_home/.cache

# A teaching sandbox on a laptop, and every one of these would be wrong in a
# Jenkins anyone could reach:
#
#   runSetupWizard=false   no unlock token to copy out of the logs
#   ALLOW_LOCAL_CHECKOUT   the lesson's repo is a bare repo on this filesystem
#                          rather than a remote, and the git plugin refuses a
#                          local path without it
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false \
-Dhudson.model.DownloadService.noSignatureCheck=true \
-Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true"
