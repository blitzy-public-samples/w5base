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
#   * The out-of-scope contrib/docker/w5base-ol9-runtime/ asset (OracleLinux +
#     mod_fcgid) is NOT used, referenced, or copied here.
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
      # -- INTENTIONALLY OMITTED ----------------------------------------------
      #    * libnet-ldap-perl / DBD::Oracle + Instant Client — Oracle & LDAP are
      #      out of scope for this base (segfault-together hazard, README L490+).
      #    * libdigest-sha1-perl — removed from Debian 12 (obsolete); the one
      #      kernel reference to Digest::SHA1 is provided via cpanm below.
    && rm -rf /var/lib/apt/lists/*

# --- Digest::SHA1 (optional; not packaged on Debian 12) ----------------------
# lib/DBIx/MyServer.pm references Digest::SHA1 and it appears in W5InstallCheck's
# OPTIONAL module set (lib/UUID/Tiny.pm falls back to core Digest::SHA). We add
# it via CPAN to match the verified working environment. Best-effort: a failure
# here must NOT break the build, because the module is strictly optional.
RUN cpanm --notest --quiet Digest::SHA1 \
      || echo "WARN: optional Digest::SHA1 not installed (safe to ignore)"

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
# COPY the build context to ${W5BASEINSTDIR} (the .dockerignore excludes .git,
# contrib/, secrets, and large binary docs). Ownership is set to w5base:daemon
# so the service account owns its own install tree. No copied file is modified.
# =============================================================================
COPY --chown=w5base:daemon . ${W5BASEINSTDIR}

# =============================================================================
# Vendored "mandatory" Perl modules — compiled at build time from
# ${W5BASEINSTDIR}/dependence/mandatory (README.txt L262-L278). Tarball contents
# are never inspected; this is a build-step path only. `umask 022` matches the
# README's build recipe.
#
# CRITICAL builds fail the image on error; best-effort builds are tolerated:
#   * RPC-Smart — the transport for the W5Server control plane and `use`d by
#     sbin/W5Event & sbin/CreateDatabaseUser. Without it nothing starts.
#   * Env-C     — Env::C is in W5InstallCheck's REQUIRED module set.
#   * DateTime-Set / Data-HexDump / Spreadsheet-WriteExcel / HTML-TagFilter —
#     optional at runtime; tolerated so a single legacy build hiccup cannot
#     block the whole environment.
#   * IPC-Smart — UNUSED by the kernel and known to fail on modern gcc/glibc;
#     attempted for completeness but never allowed to fail the build.
# =============================================================================
RUN set -eux; \
    chmod 0755 "${W5BASEINSTDIR}/docker/entrypoint.sh"; \
    cd "${W5BASEINSTDIR}/dependence/mandatory"; \
    umask 022; \
    # -- CRITICAL: RPC::Smart (W5Server control-plane transport) --------------
    ( cd RPC-Smart && perl Makefile.PL && make && make install ); \
    # -- REQUIRED: Env::C (W5InstallCheck mandatory module) ------------------
    ( tar -xzf Env-C-*.tar.gz && cd Env-C-*/ && perl Makefile.PL && make && make install ); \
    # -- Best-effort optional modules (never block the build) ----------------
    ( tar -xzf DateTime-Set-*.tar.gz && cd DateTime-Set-*/ && perl Makefile.PL && make && make install ) \
        || echo "WARN: optional DateTime-Set build skipped"; \
    ( tar -xzf Data-HexDump-*.tar.gz && cd Data-HexDump-*/ && perl Makefile.PL && make && make install ) \
        || echo "WARN: optional Data-HexDump build skipped"; \
    ( tar -xzf Spreadsheet-WriteExcel-*.tar.gz && cd Spreadsheet-WriteExcel-*/ && perl Makefile.PL && make && make install ) \
        || echo "WARN: optional Spreadsheet-WriteExcel build skipped"; \
    ( tar -xzf HTML-TagFilter-*.tar.gz && cd HTML-TagFilter-*/ && perl Makefile.PL && make && make install ) \
        || echo "WARN: optional HTML-TagFilter build skipped"; \
    # -- IPC-Smart: unused + known to fail on modern toolchains --------------
    ( cd IPC-Smart && perl Makefile.PL && make && make install ) \
        || echo "WARN: IPC-Smart skipped (UNUSED; expected to fail on modern gcc)"

# --- Network + startup contract ----------------------------------------------
# Apache listens on 80 inside the container; the host port mapping lives in
# docker-compose.yml. The entrypoint owns the full startup sequence and ends by
# exec'ing Apache in the foreground, so we deliberately set NO CMD that could
# bypass it. The path is the literal ${W5BASEINSTDIR} default (/opt/w5base).
EXPOSE 80
ENTRYPOINT ["/opt/w5base/docker/entrypoint.sh"]
