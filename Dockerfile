# syntax=docker/dockerfile:1
# =============================================================================
# W5Base / Darwin — Application-service container image
# -----------------------------------------------------------------------------
# NET-NEW, purely additive artifact (AAP Group 1). This image modernizes the
# legacy install recipe — which targeted Debian 5.0 "Lenny" + a SourceForge SVN
# checkout with a manual multi-step build (README.txt L16-L45) — into a single,
# reproducible Debian 12 (bookworm) + Apache (prefork MPM) + mod_perl2 image.
#
# Responsibilities of THIS file:
#   * install the OS Perl module set the kernel needs;
#   * compile the vendored "mandatory" Perl modules from dependence/mandatory;
#   * wire the mod_perl preload contract (via docker/apache/w5base.conf);
#   * create the w5base service account + runtime directories;
#   * hand startup off to docker/entrypoint.sh (which templates config,
#     provisions the DB, builds the schema, starts W5Server, and finally runs
#     Apache in the foreground).
#
# HARD RULES honored here:
#   * It REFERENCES — never edits — application code (bin/, lib/, mod/, sbin/,
#     sql/, etc/). Startup ordering is owned entirely by docker/entrypoint.sh.
#   * Base image tags are PINNED (debian:12, NOT :latest) for reproducibility.
#   * NO secrets are baked in; every credential arrives at runtime via env vars.
#   * Oracle (DBD::Oracle) and LDAP (Net::LDAP) are intentionally EXCLUDED —
#     loading both in one process is a documented segfault hazard, and neither
#     is part of this minimal dev/validation base.
#   * The image copies ONLY the application source tree (see the explicit COPY
#     directives below), so VCS metadata, local env files, large binary
#     handbooks, and unrelated top-level assets never enter any image layer.
# =============================================================================

# --- Base image: pinned for a reproducible environment -----------------------
# Debian 12 ships Apache 2.4.x with mod_perl2 2.0.x and a full, modern Perl
# module set — the direct successor to the README's Debian 5.0 target.
FROM debian:12

# --- Unattended apt for the whole build --------------------------------------
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=noninteractive

# --- Install root + service account ------------------------------------------
# Defaults MUST match docker/entrypoint.sh and the /opt/w5base path that
# docker/apache/w5base.conf hardcodes ($W5V2::INSTDIR + the Alias directives).
ARG W5BASEINSTDIR=/opt/w5base
ARG W5BASESRVUSER=w5base
ENV W5BASEINSTDIR=${W5BASEINSTDIR} \
    W5BASESRVUSER=${W5BASESRVUSER}

# =============================================================================
# System packages — one apt layer, then clean the lists to keep the image lean.
# Grouped and commented per the Document Code Explainability rule; comment lines
# inside the RUN are stripped by the Dockerfile parser.
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
      # -- Web server + mod_perl2 + Apache::DBI --------------------------------
      #    mod_perl2 keeps a persistent Perl interpreter inside Apache; it
      #    requires the prefork MPM (configured further below). Apache::DBI
      #    pools DB connections and is preloaded by the vhost's PerlModule.
      apache2 \
      libapache2-mod-perl2 \
      libapache-dbi-perl \
      # -- Runtime tools REQUIRED by docker/entrypoint.sh ---------------------
      #    envsubst (gettext-base) renders the *.conf.tmpl config files;
      #    htpasswd (apache2-utils) writes the HTTP Basic credential file;
      #    openssl is the entrypoint's htpasswd fallback hasher;
      #    mysqladmin/mysql (default-mysql-client) provision the DB & healthcheck.
      gettext-base \
      apache2-utils \
      openssl \
      default-mysql-client \
      # -- Build toolchain for the vendored "mandatory" Perl modules ----------
      #    perl Makefile.PL && make && make install (XS modules need gcc +
      #    libc6-dev; the perl CORE headers ship with the `perl` package).
      #    `alien` mirrors the README's toolchain for legacy .deb handling.
      make \
      gcc \
      libc6-dev \
      alien \
      # -- Repository tooling + TLS trust + CPAN client -----------------------
      #    git modernizes the SVN checkout; ca-certificates supplies TLS roots;
      #    cpanminus installs the few modules Debian 12 no longer packages.
      git \
      ca-certificates \
      cpanminus \
      # -- W5Base system Perl module set (distro-provided) --------------------
      #    Mirrors README.txt L37-L45, corrected for Debian 12 package renames:
      #      libmime-perl   -> libmime-tools-perl (MIME::Entity/Parser/Words;
      #                        MIME::Base64 is now core Perl)
      #      libgd-gd2-perl -> libgd-perl         (the modern GD package)
      libxml-smart-perl \
      libio-multiplex-perl \
      libnet-server-perl \
      libxml-dom-perl \
      libunicode-string-perl \
      libcrypt-des-perl \
      libio-stringy-perl \
      libdate-calc-perl \
      libmime-tools-perl \
      libdatetime-perl \
      libset-infinite-perl \
      libole-storage-lite-perl \
      libnetaddr-ip-perl \
      libarchive-zip-perl \
      libgd-perl \
      libsoap-lite-perl \
      libnet-ssleay-perl \
      libio-socket-ssl-perl \
      libunicode-map8-perl \
      # -- Kernel/W5InstallCheck dependencies absent from the legacy list -----
      #    Verified present on bookworm and required by the running app:
      #      DBD::mysql             — the dbi:mysql driver used by
      #                               lib/kernel/database.pm & W5InstallCheck
      #      CGI                    — removed from core Perl; InstallCheck-required
      #      Class::ISA             — removed from core Perl; used across the kernel
      #      String::Diff           — InstallCheck-required
      #      HTML::Parser/TreeBuilder/FormatText — kernel HTML handling
      #      Crypt::OpenSSL::X509   — kernel certificate handling
      #      Params::Validate       — required by the vendored DateTime::Set,
      #                               which the kernel loads via lib/kernel/date.pm
      #                               on the mod_perl preload path (Apache start)
      #      JSON                   — loaded on the mod_perl preload path
      libdbd-mysql-perl \
      libcgi-pm-perl \
      libclass-isa-perl \
      libstring-diff-perl \
      libhtml-parser-perl \
      libhtml-tree-perl \
      libhtml-format-perl \
      libcrypt-openssl-x509-perl \
      libparams-validate-perl \
      libjson-perl \
      # -- W5InstallCheck Pass-1 modules provided as reliable Debian packages --
      #    sbin/W5InstallCheck's low-level Pass 1 hard-fails (exit 1) if ANY of
      #    these modules is missing, so they are installed from distro packages
      #    (each verified present + loadable on bookworm) rather than best-effort
      #    source builds that could let the image build while the check later fails:
      #      Data::HexDump                          <- libdata-hexdump-perl
      #      DateTime::Set / ::Span / ::SpanSet     <- libdatetime-set-perl
      #      Spreadsheet::WriteExcel / ::Big        <- libspreadsheet-writeexcel-perl
      #      Spreadsheet::ParseExcel / ::SaveParser <- libspreadsheet-parseexcel-perl
      #      Object::MultiType                      <- libobject-multitype-perl
      #      Mail::Internet                         <- libmailtools-perl
      libdata-hexdump-perl \
      libdatetime-set-perl \
      libspreadsheet-writeexcel-perl \
      libspreadsheet-parseexcel-perl \
      libobject-multitype-perl \
      libmailtools-perl \
      # -- INTENTIONALLY OMITTED ----------------------------------------------
      #    * libnet-ldap-perl / DBD::Oracle + Instant Client — Oracle & LDAP are
      #      out of scope for this base (segfault-together hazard, README L490+).
      #    * libdigest-sha1-perl — not packaged on Debian 12. Digest::SHA1 IS a
      #      W5InstallCheck Pass-1 requirement, so it is installed fail-fast from
      #      CPAN below (never treated as optional).
    && rm -rf /var/lib/apt/lists/*

# --- Digest::SHA1 (REQUIRED; not packaged on Debian 12) ----------------------
# Digest::SHA1 is in sbin/W5InstallCheck's Pass-1 low-level module list, which
# hard-fails (exit 1) if it is absent — so it is NOT optional. Debian 12 no
# longer ships libdigest-sha1-perl, so we install it from CPAN and FAIL THE
# BUILD if that install fails (no best-effort masking that would let the image
# build while W5InstallCheck later fails).
RUN cpanm --notest --quiet Digest::SHA1

# =============================================================================
# Apache module + MPM configuration.
# mod_perl2 REQUIRES the prefork MPM — the threaded event/worker MPMs crash
# mod_perl. We force prefork and enable exactly the modules the W5Base vhost
# (docker/apache/w5base.conf) relies on.
# =============================================================================
RUN set -eux; \
    # Switch to the prefork MPM (mandatory for mod_perl2).
    a2dismod mpm_event mpm_worker 2>/dev/null || true; \
    a2enmod mpm_prefork; \
    # perl (preload), rewrite/proxy/alias (URL routing to bin/app.pl), mime
    # (AddHandler), and the auth stack backing the minimal HTTP Basic login.
    a2enmod perl rewrite proxy alias mime authn_core authn_file authz_user auth_basic; \
    # The stock default site also binds *:80 and would shadow our vhost.
    a2dissite 000-default 2>/dev/null || true; \
    # Set a global ServerName so Apache does not emit the cosmetic AH00558
    # "could not reliably determine the server's fully qualified domain name"
    # warning on startup. The vhost's own ServerName still applies per-request.
    printf 'ServerName localhost\n' > /etc/apache2/conf-available/w5base-servername.conf; \
    a2enconf w5base-servername

# --- Enable the W5Base virtual host ------------------------------------------
# The vhost realizes the mod_perl preload contract from
# etc/httpd/perl.conf.mod_perl2 (PerlModule Apache::DBI + a <Perl> block that
# sets $W5V2::INSTDIR and requires sbin/ApacheStartup.pl). It is parsed only
# when Apache actually starts (at runtime, from the entrypoint), by which time
# the source tree and all Perl modules are present.
COPY docker/apache/w5base.conf /etc/apache2/sites-available/w5base.conf
RUN a2ensite w5base

# =============================================================================
# Service account + runtime directories.
# Mirrors README.txt L215-L240 and docker/entrypoint.sh exactly: the w5base
# user's primary group is `daemon`, Apache's www-data joins `daemon`, and the
# runtime dirs are mode 2770 owned by w5base:daemon so both processes share
# them. Everything is idempotent, so the entrypoint's own creation is a no-op.
# The container runs as root (the entrypoint must create users/dirs and W5Server
# self-drops privileges) — hence NO `USER` directive.
# =============================================================================
RUN set -eux; \
    getent group daemon >/dev/null 2>&1 || groupadd --system daemon; \
    id "${W5BASESRVUSER}" >/dev/null 2>&1 \
      || useradd --system --home-dir "${W5BASEINSTDIR}" --no-create-home \
                 --shell /usr/sbin/nologin --gid daemon "${W5BASESRVUSER}"; \
    usermod -aG daemon www-data || true; \
    for d in /etc/w5base /var/opt/w5base /var/opt/w5base/state /var/log/w5base; do \
      install -d -m 2770 -o "${W5BASESRVUSER}" -g daemon "$d"; \
    done

# =============================================================================
# Application source placement.
# Copy ONLY the application source tree that the runtime and build need, each
# path owned by the w5base:daemon service account. Enumerating the directories
# explicitly (instead of `COPY . `) keeps VCS metadata, local env files (which
# may hold real secrets), large binary handbooks, and unrelated top-level trees
# OUT of every image layer — with no dependency on an external ignore file. No
# copied file is modified. What each path is for:
#   bin lib mod sbin sql etc -> Perl kernel, data-object modules, shell entry
#                               points, schema scripts, and the framework config
#                               defaults (etc/w5base/default.conf) that the
#                               rendered /etc/w5base configs inherit
#   skin static              -> assets required for the main menu to render
#   docker                   -> entrypoint + config templates used at runtime
#   dependence               -> vendored "mandatory" Perl modules built below
# =============================================================================
COPY --chown=w5base:daemon bin/        ${W5BASEINSTDIR}/bin/
COPY --chown=w5base:daemon lib/        ${W5BASEINSTDIR}/lib/
COPY --chown=w5base:daemon mod/        ${W5BASEINSTDIR}/mod/
COPY --chown=w5base:daemon sbin/       ${W5BASEINSTDIR}/sbin/
COPY --chown=w5base:daemon sql/        ${W5BASEINSTDIR}/sql/
COPY --chown=w5base:daemon etc/        ${W5BASEINSTDIR}/etc/
COPY --chown=w5base:daemon skin/       ${W5BASEINSTDIR}/skin/
COPY --chown=w5base:daemon static/     ${W5BASEINSTDIR}/static/
COPY --chown=w5base:daemon docker/     ${W5BASEINSTDIR}/docker/
COPY --chown=w5base:daemon dependence/ ${W5BASEINSTDIR}/dependence/
COPY --chown=w5base:daemon README.txt README.ConfigParameters.txt README.AppCom.txt W5Server.README.txt LICENSE ${W5BASEINSTDIR}/

# =============================================================================
# Vendored "mandatory" Perl modules — compiled at build time from
# ${W5BASEINSTDIR}/dependence/mandatory (README.txt L262-L278). Tarball contents
# are never inspected; this is a build-step path only. `umask 022` matches the
# README's build recipe.
#
# ONLY the modules that are genuinely required AND are not available as a
# reliable Debian package are built here, and EVERY one FAILS THE BUILD on error
# (no best-effort masking that could let the image build while sbin/W5InstallCheck
# later fails):
#   * RPC-Smart      — transport for the W5Server control plane; `use`d by
#                      sbin/W5Event & sbin/CreateDatabaseUser and listed in
#                      W5InstallCheck Pass 1. Without it nothing starts.
#   * Env-C          — Env::C is in W5InstallCheck's required module set.
#   * HTML-TagFilter — HTML::TagFilter is marked MANDATORY by
#                      mod/faq/ext/InstallCheck.pm and is not packaged on Debian 12.
#
# Deliberately NOT built here:
#   * DateTime-Set / Data-HexDump / Spreadsheet-WriteExcel — also W5InstallCheck
#     requirements, but installed above from reliable Debian packages
#     (libdatetime-set-perl / libdata-hexdump-perl / libspreadsheet-writeexcel-perl),
#     so no source build is needed.
#   * IPC-Smart — unused by the kernel, absent from every W5InstallCheck probe
#     (the check exits 0 without it), and does not compile on a modern gcc/glibc
#     toolchain. Building it would add only a guaranteed-failing step, so it is
#     omitted entirely rather than tolerated as a masked failure.
# =============================================================================
RUN set -eux; \
    chmod 0755 "${W5BASEINSTDIR}/docker/entrypoint.sh"; \
    cd "${W5BASEINSTDIR}/dependence/mandatory"; \
    umask 022; \
    # -- RPC::Smart (W5Server control-plane transport; Pass-1 required) -------
    ( cd RPC-Smart && perl Makefile.PL && make && make install ); \
    # -- Env::C (W5InstallCheck required module) -----------------------------
    ( tar -xzf Env-C-*.tar.gz && cd Env-C-*/ && perl Makefile.PL && make && make install ); \
    # -- HTML::TagFilter (mandatory per mod/faq/ext/InstallCheck.pm) ----------
    ( tar -xzf HTML-TagFilter-*.tar.gz && cd HTML-TagFilter-*/ && perl Makefile.PL && make && make install )

# --- Network + startup contract ----------------------------------------------
# Apache listens on 80 inside the container; the host port mapping lives in
# docker-compose.yml. The entrypoint owns the full startup sequence and ends by
# exec'ing Apache in the foreground, so we deliberately set NO CMD that could
# bypass it. The path is the literal ${W5BASEINSTDIR} default (/opt/w5base).
EXPOSE 80
ENTRYPOINT ["/opt/w5base/docker/entrypoint.sh"]
