FROM registry.suse.com/bci/bci-init:latest

RUN zypper ar -Gf https://download.opensuse.org/repositories/devel:/languages:/perl/15.5/ d-l-perl
RUN zypper ar -Gf https://download.opensuse.org/repositories/devel:/libraries:/c_c++/15.5/ d-l-cpp
RUN zypper --non-interactive in --allow-vendor-change -y gcc make perl-CPAN-Mini postgresql-server-devel libexpat-devel libcmark0_30_2 gmp-devel cmark-devel
RUN cpan -fi CPAN App::cpanminus

WORKDIR /openqa

RUN --mount=type=bind,source=./,target=/openqa cpanm -vn --installdeps .
