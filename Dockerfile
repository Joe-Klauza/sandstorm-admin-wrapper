FROM ruby:3-slim-bookworm


RUN apt-get update

# General dependencies
RUN apt-get install -y wget make gcc

# Install Steamcmd dependencies
RUN apt-get install -y lib32gcc-s1

# Install Locales package for Steamcmd to avoid Warnings about being not being able to set to en_US.UTF-8
RUN apt-get install -y locales && \
    # Override all localisation settings to en_US.UTF-8 as default
    echo "LC_ALL=en_US.UTF-8" >> /etc/environment && \
    # Tell locale.gen to generate en_US.UTF-8 with UTF-8 encoding
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && \
    # Set the default language to en_US.UTF-8
    echo "LANG=en_US.UTF-8" > /etc/locale.conf && \
    # Run locale-gen to ensure en_US.UTF-8 is generated
    locale-gen en_US.UTF-8

# Sandstorm server won't run under root
RUN useradd -ms /bin/bash sandstorm

USER sandstorm
WORKDIR /home/sandstorm

COPY --chown=sandstorm:sandstorm . .

RUN wget https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
RUN mv steamcmd_linux.tar.gz steamcmd/installation/
RUN cd steamcmd/installation && tar -xvf steamcmd_linux.tar.gz
RUN rm steamcmd/installation/steamcmd_linux.tar.gz

# Add config for docker container

RUN cp config/config.toml.docker config/config.toml

RUN gem install bundler

WORKDIR /home/sandstorm/admin-interface

RUN /bin/bash -c bundle

WORKDIR /home/sandstorm

CMD ./docker_start.sh
