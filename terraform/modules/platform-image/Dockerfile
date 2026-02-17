FROM registry.access.redhat.com/ubi9/ubi-minimal:9.7-1770267347

# Tool versions - update these and rebuild to upgrade
ARG KUBECTL_VERSION=v1.31.0
ARG HELM_VERSION=v3.16.0
ARG K9S_VERSION=v0.32.5
ARG STERN_VERSION=1.30.0
ARG YQ_VERSION=v4.44.3
ARG OC_VERSION=4.16.0
ARG TERRAFORM_VERSION=1.14.3

# Install base packages
RUN microdnf install -y \
      tar \
      gzip \
      unzip \
      jq \
      git \
      less \
      vim-enhanced \
      which \
      procps-ng \
      bind-utils \
      shadow-utils \
      python3 \
      python3-pip \
      postgresql && \
    microdnf clean all && \
    rm -rf /var/cache/yum

# Install AWS CLI v2
RUN curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

# Install kubectl
RUN curl -sL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Install helm
RUN curl -sL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/linux-amd64/helm /usr/local/bin/helm && \
    chmod +x /usr/local/bin/helm && \
    rm -rf /tmp/linux-amd64

# Install k9s
RUN curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/k9s /usr/local/bin/k9s && \
    chmod +x /usr/local/bin/k9s

# Install stern
RUN curl -sL "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_amd64.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/stern /usr/local/bin/stern && \
    chmod +x /usr/local/bin/stern

# Install yq
RUN curl -sL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Install OpenShift CLI (oc)
RUN curl -sL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/oc /usr/local/bin/oc && \
    chmod +x /usr/local/bin/oc && \
    rm -f /tmp/kubectl /tmp/README.md

# Install Terraform
RUN curl -sL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o "/tmp/terraform.zip" && \
    unzip /tmp/terraform.zip -d /usr/local/bin/ && \
    rm -f /tmp/terraform.zip

# Install Docker CLI (for CodeBuild usage)
RUN curl -sL "https://download.docker.com/linux/static/stable/x86_64/docker-24.0.5.tgz" -o "/tmp/docker.tgz" && \
    tar -xz -C /tmp -f /tmp/docker.tgz && \
    mv /tmp/docker/docker /usr/local/bin/docker && \
    chmod +x /usr/local/bin/docker && \
    rm -rf /tmp/docker /tmp/docker.tgz

# Run as root (required for CodeBuild Docker access and typical CI/CD operations)
# Previous configuration used user 65534 (nobody), but removed to support CI/CD use cases
ENV HOME=/root
WORKDIR /root
