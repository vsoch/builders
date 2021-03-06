#!/bin/bash

################################################################################
# Instance Preparation
# For Google cloud, Stackdriver/logging should have Write, 
#                   Google Storage should have Full
#                   All other APIs None,
#
# This script adds a time and valgrind command to output build and runtime 
# metrics that can be compared across container builds
#
# Copyright (C) 2018 The Board of Trustees of the Leland Stanford Junior
# University.
# Copyright (C) 2018 Vanessa Sochat.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
# License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
################################################################################

# Logging

WEBROOT=/var/www/html
MASSIF="${WEBROOT}/massif.log"
WEBLOG="${WEBROOT}/sregistry.log"
sudo touch $WEBLOG && sudo chmod 757 $WEBLOG
sudo touch $MASSIF && sudo chmod 757 $MASSIF
echo "Installing Singularity Dependencies" | tee -a $WEBLOG

sudo apt-get -y install git \
                   build-essential \
                   libtool \
                   libarchive-dev \
                   squashfs-tools \
                   autotools-dev \
                   automake \
                   autoconf \
                   debootstrap \
                   yum \
                   time \
                   valgrind \
                   uuid-dev \
                   libssl-dev


echo "Preparing logging..." | tee -a $WEBLOG
IPADDRESS=`echo $(hostname -I) | xargs`
echo "Logs available at http://$IPADDRESS/" | tee -a $WEBLOG


# Robot Web Reporter

if [ -f "index.html" ]; then
    sudo cp index.html $WEBROOT
    sudo mv assets $WEBROOT/assets
else
    echo "Cannot find web index.html file in $PWD";
fi

# Metadata

METADATA="http://metadata/computeMetadata/v1/instance/attributes"
HEAD="Metadata-Flavor: Google"

SINGULARITY_REPO=$(curl ${METADATA}/SINGULARITY_REPO -H "${HEAD}")
SINGULARITY_BRANCH=$(curl ${METADATA}/SINGULARITY_BRANCH -H "${HEAD}")
SINGULARITY_RECIPE=$(curl ${METADATA}/SINGULARITY_RECIPE -H "${HEAD}")
SINGULARITY_COMMIT=$(curl ${METADATA}/SINGULARITY_COMMIT -H "${HEAD}")
SREGISTRY_USER_REPO=$(curl ${METADATA}/SREGISTRY_USER_REPO -H "${HEAD}")
SREGISTRY_USER_BRANCH=$(curl ${METADATA}/SREGISTRY_USER_BRANCH -H "${HEAD}")
SREGISTRY_USER_COMMIT=$(curl ${METADATA}/SREGISTRY_USER_COMMIT -H "${HEAD}")
SREGISTRY_USER_TAG=$(curl ${METADATA}/SREGISTRY_USER_TAG -H "${HEAD}")
SREGISTRY_CONTAINER_NAME=$(curl ${METADATA}/SREGISTRY_CONTAINER_NAME -H "${HEAD}")

MACHINE_TYPE=$(curl http://metadata.google.internal/computeMetadata/v1/instance/machine-type -H "${HEAD}")

SREGISTRY_BUILDER_STORAGE_BUCKET=$(curl ${METADATA}/SREGISTRY_BUILDER_STORAGE_BUCKET -H "${HEAD}")
SREGISTRY_GOOGLE_STORAGE_PRIVATE=$(curl ${METADATA}/SREGISTRY_GOOGLE_STORAGE_PRIVATE -H "${HEAD}")

# User Repo Tag and branch

if [ ! -n "${SREGISTRY_USER_TAG:-}" ]; then
    SREGISTRY_USER_TAG=latest
fi
if [ ! -n "${SREGISTRY_USER_BRANCH:-}" ]; then
    SREGISTRY_USER_BRANCH=master
fi

echo "
# SINGULARITY

SINGULARITY_REPO: ${SINGULARITY_REPO}
    The Singularity repository being cloned by the builder. 
SINGULARITY_BRANCH: ${SINGULARITY_BRANCH}
    The branch of the repository being used.
SINGULARITY_COMMIT: ${SINGULARITY_COMMIT}
    If defined, a particular commit to checkout.

# SETTINGS

SREGISTRY_USER_REPO: ${SREGISTRY_USER_REPO}
    Your repository we are building from!
SINGULARITY_RECIPE: ${SINGULARITY_RECIPE}
    The recipe file in queue for build!
SREGISTRY_USER_BRANCH: ${SREGISTRY_USER_BRANCH}
    The branch we are cloning to do your build.
SREGISTRY_USER_TAG: ${SREGISTRY_USER_TAG}
     The tag for the image.
SREGISTRY_GOOGLE_STORAGE_PRIVATE: ${SREGISTRY_GOOGLE_STORAGE_PRIVATE}
    Building a private image?
" | tee -a $WEBLOG


# Singularity

BUILDDIR=$PWD
echo "# Installing Singularity" | tee -a $WEBLOG
echo
echo "git clone -b $SINGULARITY_BRANCH $SINGULARITY_REPO" | tee -a $WEBLOG
cd /tmp && git clone -b $SINGULARITY_BRANCH $SINGULARITY_REPO singularity && cd singularity

# Commit

if [ -n "${SINGULARITY_COMMIT}" ]; then
    git checkout $SINGULARITY_COMMIT .
else
    SINGULARITY_COMMIT=$(git log -n 1 --pretty=format:"%H")
fi

echo "Using commit ${SINGULARITY_COMMIT}" | tee -a $WEBLOG


# Install

./autogen.sh && ./configure --prefix=/usr/local && make && sudo make install && sudo make secbuildimg
RETVAL=$?
echo "Install return value $RETVAL" | tee -a $WEBLOG
echo $(which singularity) | tee -a $WEBLOG

cd $BUILDDIR

# User Repo

# Clone

echo
echo "Build"
echo
echo "Cloning User Repository $SREGISTRY_USER_REPO" | tee -a $WEBLOG
echo "git clone -b $SREGISTRY_USER_BRANCH $SREGISTRY_USER_REPO" | tee -a $WEBLOG
git clone -b $SREGISTRY_USER_BRANCH $SREGISTRY_USER_REPO build-repo && cd build-repo

# Commit

if [ -n "${SREGISTRY_USER_COMMIT:-}" ]; then
    git checkout $SREGISTRY_USER_COMMIT .
else
    SREGISTRY_USER_COMMIT=$(git log -n 1 --pretty=format:"%H")
fi

echo "Using commit ${SREGISTRY_USER_COMMIT}" | tee -a $WEBLOG

# Build

CONTAINER=$SREGISTRY_USER_COMMIT.simg

if [ -f "$SINGULARITY_RECIPE" ]; then

    # Record time and perform build

    echo "Found recipe: ${SINGULARITY_RECIPE}" | tee -a $WEBLOG
    echo "Start Time: $(date)." | tee -a $WEBLOG
    sudo singularity build --isolated $CONTAINER "${SINGULARITY_RECIPE}" | tee -a $WEBLOG

    # Assess return value
    ret=$?
    echo "Return value of ${ret}." | tee -a $WEBLOG
    if [ $ret -eq 137 ]; then
        echo "Killed: $(date)." | tee -a $WEBLOG
    else
        echo "End Time: $(date)." | tee -a $WEBLOG
    fi

else

    # The recipe was not found!

    echo "${SINGULARITY_RECIPE} is not found."  | tee -a $WEBLOG
    ls | tee -a $WEBLOG
fi


# Storage

if [ -f ${CONTAINER} ]; then

    echo 
    echo "# Metrics"
    echo

    # Here is the test line to output to the massif file

    singularity run --bind data/:/scif/data $CONTAINER run valgrind
    mv data/massif* data/massif.out
    sudo cp data/massif.out $MASSIF
    sudo touch $MASSIF && sudo chmod 757 $MASSIF
    ms_print $MASSIF >> massif-plot.log
    sudo mv massif-plot.log $WEBROOT && sudo chmod 757 $WEBROOT/massif-plot.log
    echo $MACHINE_TYPE >> data/machine-type.txt

    STORAGE_FOLDER="gs://$SREGISTRY_BUILDER_STORAGE_BUCKET/github.com/$SREGISTRY_CONTAINER_NAME/$SREGISTRY_USER_BRANCH/$SREGISTRY_USER_COMMIT"
    CONTAINER_HASH=($(sha256sum "${CONTAINER}"))
    CONTAINER_UPLOAD="${STORAGE_FOLDER}/$CONTAINER_HASH.tar.gz"

    # Compress up data folder based on hash
    tar -zcvf $CONTAINER_HASH.tar.gz data

    echo "Upload with format: 
[storage-bucket]     : ${SREGISTRY_BUILDER_STORAGE_BUCKET} 
[github-namespace]   : github.com/[container]/[branch]/[commit]
  [container]        : ${SREGISTRY_CONTAINER_NAME}
  [commit]           : ${SREGISTRY_USER_COMMIT}
  [branch]           : ${SREGISTRY_USER_BRANCH}
[sha256sum]          : ${CONTAINER_HASH}
[tag]                : ${SREGISTRY_USER_TAG}
gs://[storage-bucket]/github.com/[github-namespace]/[sha256sum].tar.gz

${CONTAINER_UPLOAD}
" | tee -a $WEBLOG

    # Does the user want the container to be private?
    if [ "$SREGISTRY_GOOGLE_STORAGE_PRIVATE" == "true" ]; then
        PRIVATE=""
    else
        PRIVATE="-a public-read"
    fi

    echo "gsutil cp $PRIVATE $CONTAINER_HASH.tar.gz $CONTAINER_UPLOAD"  | tee -a $WEBLOG
    gsutil -h "x-goog-meta-type:metrics" \
           -h "x-goog-meta-client:sregistry" \
           -h "x-goog-meta-tag:${SREGISTRY_USER_TAG}" \
           -h "x-goog-meta-commit:${SREGISTRY_USER_COMMIT}" \
           -h "x-goog-meta-hash:${CONTAINER_HASH}" \
           -h "x-goog-meta-uri:${SREGISTRY_CONTAINER_NAME}:${SREGISTRY_USER_TAG}@${SREGISTRY_USER_COMMIT}" \
           cp $PRIVATE $CONTAINER_HASH.tar.gz $CONTAINER_UPLOAD | tee -a $WEBLOG

else
    echo "Container was not built, skipping upload to storage."  | tee -a $WEBLOG    
fi

# Return to build bundle folder, in case other stuffs to do.

# Regardless of success, finalize Log and upload
LOG_UPLOAD="${STORAGE_FOLDER}/${CONTAINER_HASH}:${SREGISTRY_USER_TAG}.log"

if [ -f "$WEBLOG" ]; then
    echo "Uploading ${WEBLOG} to ${LOG_UPLOAD}"
    gsutil cp $PRIVATE "${WEBLOG}" "${LOG_UPLOAD}"
else
    echo "Skipping upload of ${WEBLOG}, does not exist."
fi

cd $BUILDDIR
