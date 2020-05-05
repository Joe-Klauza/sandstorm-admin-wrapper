FROM ruby:2.7-slim-buster

WORKDIR /home/sandstorm

RUN apt-get update

# General dependencies
RUN apt-get install -y wget make gcc

# Install Steamcmd dependencies
RUN apt-get install -y lib32gcc1

COPY . .

RUN wget https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
RUN mv steamcmd_linux.tar.gz steamcmd/installation/
RUN cd steamcmd/installation && tar -xvf steamcmd_linux.tar.gz
RUN rm steamcmd/installation/steamcmd_linux.tar.gz

RUN steamcmd/installation/steamcmd.sh +login anonymous +force_install_dir /home/sandstorm/sandstorm-server +app_update 581330 +quit

RUN gem install bundler:1.17.2 

CMD ./linux_start.sh
