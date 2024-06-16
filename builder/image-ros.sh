#! /usr/bin/env bash

#
# Script for build the image. Used builder script of the target repo
# For build: docker run --privileged -it --rm -v /dev:/dev -v $(pwd):/builder/repo smirart/builder
#
# Copyright (C) 2018 Copter Express Technologies
#
# Author: Artem Smirnov <urpylka@gmail.com>
#
# Distributed under MIT License (available at https://opensource.org/licenses/MIT).
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#

set -ex # exit on error, echo commands

# Current ROS distribution
ROS_DISTRO=noetic
. /etc/os-release # set $VERSION_CODENAME to Debian release code name
export ROS_OS_OVERRIDE=debian:$VERSION_CODENAME

# https://gist.github.com/letmaik/caa0f6cc4375cbfcc1ff26bd4530c2a3
# https://github.com/travis-ci/travis-build/blob/master/lib/travis/build/templates/header.sh
my_travis_retry() {
  local result=0
  local count=1
  local max_count=5
  while [ $count -le $max_count ]; do
    [ $result -ne 0 ] && {
      echo -e "\nThe command \"$*\" failed. Retrying, $count of $max_count.\n" >&2
    }
    # ! { } ignores set -e, see https://stackoverflow.com/a/4073372
    ! { "$@"; result=$?; }
    [ $result -eq 0 ] && break
    count=$(($count + 1))
    sleep 1
  done

  [ $count -gt $max_count ] && {
    echo -e "\nThe command \"$*\" failed $max_count times.\n" >&2
  }

  return $result
}

echo "--- Install rosdep"
my_travis_retry pip3 install -U rosdep

# TODO: 'kinetic-rosdep-clover.yaml' should add only if we use our repo?
echo "--- Init rosdep"
my_travis_retry rosdep init

echo "--- Update rosdep"
echo "yaml file:///etc/ros/rosdep/${ROS_DISTRO}-rosdep-clover.yaml" >> /etc/ros/rosdep/sources.list.d/10-clover.list
my_travis_retry rosdep update

echo "--- Populate rosdep for ROS user"
my_travis_retry sudo -u pi ROS_OS_OVERRIDE=debian:$VERSION_CODENAME rosdep update

# echo "Reconfiguring Clover repository for simplier unshallowing"
cd /home/pi/catkin_ws/src/clover
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"

# This is sort of a hack to force "custom" packages to be installed - the ones built by COEX, linked against OpenCV 4.2
# I **wish** OpenCV would not be such a mess, but, well, here we are.
# echo "--- Installing OpenCV 4.2-compatible ROS packages"
# apt install -y --no-install-recommends \
# ros-${ROS_DISTRO}-compressed-image-transport=1.14.0-0buster \
# ros-${ROS_DISTRO}-cv-bridge=1.15.0-0buster \
# ros-${ROS_DISTRO}-cv-camera=0.5.1-0buster \
# ros-${ROS_DISTRO}-image-publisher=1.15.3-0buster \
# ros-${ROS_DISTRO}-web-video-server=0.2.1-0buster
# apt-mark hold \
# ros-${ROS_DISTRO}-compressed-image-transport \
# ros-${ROS_DISTRO}-cv-bridge \
# ros-${ROS_DISTRO}-cv-camera \
# ros-${ROS_DISTRO}-image-publisher \
# ros-${ROS_DISTRO}-web-video-server

#echo "--- Installing libboost-dev" # https://travis-ci.org/github/CopterExpress/clover/jobs/766318908#L6536
#my_travis_retry apt-get install -y --no-install-recommends libboost-dev libboost-all-dev

echo "--- Build and install Clover"
cd /home/pi/catkin_ws
# Don't try to install gazebo_ros
my_travis_retry rosdep install -y --from-paths src --ignore-src --rosdistro ${ROS_DISTRO} --os=debian:$VERSION_CODENAME \
  --skip-keys="gazebo_ros gazebo_plugins"
my_travis_retry pip3 install wheel
my_travis_retry pip3 install -r /home/pi/catkin_ws/src/clover/clover/requirements.txt
source /opt/ros/${ROS_DISTRO}/setup.bash
catkin_make -j2 -DCMAKE_BUILD_TYPE=RelWithDebInfo
source devel/setup.bash

echo "--- Install clever package (for backwards compatibility)"
cd /home/pi/catkin_ws/src/clover/builder/assets/clever
./setup.py install
rm -rf build  # remove build artifacts

echo "--- Build Clover documentation"
cd /home/pi/catkin_ws/src/clover
builder/assets/install_gitbook.sh
gitbook install
gitbook build
# replace assets copy to assets symlink to save space
rm -rf _book/assets && ln -s ../docs/assets _book/assets
touch node_modules/CATKIN_IGNORE docs/CATKIN_IGNORE _book/CATKIN_IGNORE clover/www/CATKIN_IGNORE apps/CATKIN_IGNORE # ignore documentation files by catkin
npm cache clean --force

echo "--- Installing additional ROS packages"
my_travis_retry apt-get install -y --no-install-recommends \
    ros-${ROS_DISTRO}-rosbridge-suite \
    ros-${ROS_DISTRO}-rosserial \
    ros-${ROS_DISTRO}-usb-cam \
    ros-${ROS_DISTRO}-vl53l1x \
    ros-${ROS_DISTRO}-ws281x \
    ros-${ROS_DISTRO}-libcamera-ros \
    ros-${ROS_DISTRO}-rosshow \
    ros-${ROS_DISTRO}-cmake-modules \
    ros-${ROS_DISTRO}-image-view \
    ros-${ROS_DISTRO}-nodelet-topic-tools \
    ros-${ROS_DISTRO}-stereo-msgs

# TODO move GeographicLib datasets to Mavros debian package
echo "--- Install GeographicLib datasets (needed for mavros)" \
&& wget -qO- https://raw.githubusercontent.com/mavlink/mavros/master/mavros/scripts/install_geographiclib_datasets.sh | bash

echo "--- Running tests"
export ROS_IP='127.0.0.1' # needed for running tests
cd /home/pi/catkin_ws
# FIXME: Investigate failing tests
catkin_make run_tests #&& catkin_test_results

echo "--- Change permissions for catkin_ws"
chown -Rf pi:pi /home/pi/catkin_ws

echo "--- Update www"
sudo -u pi sh -c ". devel/setup.sh && rosrun clover www"

echo "--- Make \$HOME/examples symlink"
ln -s "$(catkin_find clover examples --first-only)" /home/pi
chown -Rf pi:pi /home/pi/examples

echo "--- Make systemd services symlinks"
ln -s /home/pi/catkin_ws/src/clover/builder/assets/clover.service /lib/systemd/system/
ln -s /home/pi/catkin_ws/src/clover/builder/assets/roscore.service /lib/systemd/system/
# validate
[ -f /lib/systemd/system/clover.service ]
[ -f /lib/systemd/system/roscore.service ]

echo "--- Make udev rules symlink"
ln -s "$(catkin_find clover udev --first-only)"/* /lib/udev/rules.d/

echo "--- Setup ROS environment"
cat << EOF >> /home/pi/.bashrc
LANG='C.UTF-8'
LC_ALL='C.UTF-8'
export ROS_HOSTNAME=\`hostname\`.local
export ROS_OS_OVERRIDE=debian:bookworm
source /opt/ros/${ROS_DISTRO}/setup.bash
source /home/pi/catkin_ws/devel/setup.bash
EOF

echo "--- Cleanup apt"
apt-get autoremove --purge -y
apt-get clean

echo "--- Cleanup pip"
pip3 cache purge

echo "--- Cleanup /tmp"
rm -rf /tmp/*
