#############
# hosted-ce #
#############

FROM base:latest
LABEL maintainer "OSG Software <help@osg-htc.org>"
LABEL name "hosted-ce"

ARG BASE_YUM_REPO=release

RUN yum install -y osg-ce-bosco \
                   htcondor-ce-view && \
    rm -rf /var/cache/yum/

COPY etc/osg/image-config.d/ /etc/osg/image-config.d/

# Use "ssh -q" in bosco_cluster until the chang has been upstreamed to condor
# Enable bosco_cluster xtrace
COPY tmp/ /tmp

# SOFTWARE-5613: override package versions of remote WN client scripts
# to allow for a faster dev -> ops turnaround
COPY usr/bin/ /usr/bin

# Handle bosco_cluster -> condor_remote_cluster symlink
RUN sed -i 's/bosco_cluster/condor_remote_cluster/g' /tmp/*.patch && \
    patch -d / -p0 < /tmp/ssh_q.patch && \
    patch -d / -p0 < /tmp/bosco_cluster_xtrace.patch


COPY usr/local/bin /usr/local/bin
