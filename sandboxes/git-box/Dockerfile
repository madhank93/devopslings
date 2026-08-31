# A small Debian box with git and git-lfs.
#
# Module 08 runs on the host: a git lesson needs nothing but git, and a student
# learns more from breaking and fixing a repository in their own shell. One
# lesson cannot — git-lfs is a separate package that many machines do not have,
# and a lesson whose first step is "install this" grades the student's package
# manager. So that lesson gets a box, and only that lesson.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      git git-lfs \
      ca-certificates \
      less file procps \
    && rm -rf /var/lib/apt/lists/*

# An identity and a default branch, so no lesson task has to set them and no
# commit fails with "please tell me who you are".
RUN git config --system user.email dev@example.com \
    && git config --system user.name 'Dev' \
    && git config --system init.defaultBranch main

WORKDIR /work
CMD ["sleep", "infinity"]
