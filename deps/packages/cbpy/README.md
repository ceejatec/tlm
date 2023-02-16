# Overview

This directory contains build steps to create "cbpy", which is a
standalone customized Python 3 package. This package will be installed
on customer machines as part of Server, and will be used for all Python
3 scripts that we ship.

Therefore, if you write any Python 3 scripts that require a new third-party
Python library, we must add it here to ensure that it is available in
production.

This used to be part of the Server build itself, but as it grew somewhat
more complex, it made sense to pull it out to a separate build. I'm
making this a cbdeps 1.0 package (ie, here in tlm/deps/packages rather
than driven by a separate manifest) because this actually IS effectively
part of the Server build. This also means we can keep the
couchbase-server-specific Black Duck manifest here in the same location
as the environment files which define what python libraries are
included, making it easier to keep them in sync.

# Adding new packages or updating package versions

Simply edit the file cb-dependencies.txt to specify new dependencies
that are required on all platforms. If there are some which are
platform-specific, edit one or more of the five cb-dependencies-*.txt
files for the specific platform/arch(es) you need.

# Custom packages

If there is a package we need that isn't available in conda-forge, we
can create a conda package recipe in a directory under conda-pkgs/all.
This at a minimum requires a file named "meta.yaml" which describes how
to build the package. See the link below for additional information:

https://docs.conda.io/projects/conda-build/en/latest/resources/define-metadata.html

# Stubbed packages

We have a few packages that we stub out, generally because something we
require depends on them but we don't actually need/want to ship them
(often due to suspect licensing conditions). In that case, we can create
a "fake" conda pacakge in a directory under conda-pkgs/stubs. The recipe
format is the same as above, although most of the information is left
blank.

When doing this, also add a declaration of the stubbed dependency to the
file cb-dependencies-stubs.txt.

# Building packages

This is still a cbdeps V1 package, so don't forget to also edit the
version and/or build number in tlm/deps/packages/CMakeLists.txt.

Once you've made any necessary changes, submit the change to Gerrit,
then run the job
http://server.jenkins.couchbase.com/job/cbdeps-build-old/ and specify
your change. It is probably best to only propose changes to the 'master'
git branch of tlm.

# Generating new environment files

When the containers/scripts have been run on all platforms, you should have:

    package-lists/
        linux-aarch64
        linux-x86_64
        osx-x86_64
        osx-arm64
        win

At that point, run `create-environment-files.py`. It will error out if
blackduck manifest changes are required, if no blackduck changes
are needed the new environment-*.txt files will be created.
