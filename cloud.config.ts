import type { CloudConfig } from '@stacksjs/ts-cloud'

/**
 * ts-cloud deployment config for home-lang.org.
 *
 * One BunPress build serves everything: the landing page at the apex and the
 * documentation under `/docs`, which is why every doc page is a file under
 * `docs/docs/`. `docs.home-lang.org` is kept as a redirect so old links land
 * on the equivalent page rather than a dead host.
 *
 * The whole deploy is this file. There is deliberately no wrapper script:
 * `bunx @stacksjs/ts-cloud deploy --env production --yes` builds, packages,
 * ships, reconciles DNS and reloads the gateway on its own.
 *
 * Two rules come with being a TENANT on a box owned by another project
 * (`cloud.attachTo`), and both have caused outages on this box before:
 *
 *   1. `project.slug` names the files this deploy OWNS:
 *      `/etc/rpx/sites.d/<slug>.json` and `rpx-cert-renew-<slug>.*`. The
 *      fragment is replaced wholesale, so the slug must stay `home-lang` and
 *      must never be `stacks`.
 *   2. Static sites need no port, so there is nothing to collide with. If a
 *      server app is ever added here, pick its port from a live `ss -lntp` on
 *      the box rather than from any config file.
 *
 * @see https://github.com/stacksjs/ts-cloud
 */
const config: CloudConfig = {
  project: {
    name: 'home-lang',
    slug: 'home-lang',
    region: 'us-east-1',
  },

  environments: {
    production: {
      type: 'production',
      deployBranch: 'main',
      variables: {
        NODE_ENV: 'production',
      },
    },
  },

  // Join the box the `stacks` project provisions instead of creating one. The
  // deploy adds this app's rpx fragment and reloads the gateway; it never
  // touches the box lifecycle or the other tenants.
  cloud: {
    provider: 'hetzner',
    attachTo: 'stacks',
  },

  hetzner: {
    // apiToken falls back to HCLOUD_TOKEN in the environment.
    location: 'fsn1',
    image: 'ubuntu-24.04',
    sshUser: 'root',
  },

  infrastructure: {
    // `_submodules` holds vendored upstreams (the typescript-go checkout), which
    // this repo neither owns nor ships — the deploy artifact is `dist/docs`.
    // Its compiler baselines contain identifiers long enough to trip the
    // pre-deploy AWS-key heuristic (`publicVarWithPrivateModulePropertyTypes`
    // matches six times), which blocked the deploy on code that is not ours and
    // never leaves this machine.
    security: { scan: { exclude: ['_submodules'] } },

    compute: {
      mode: 'server',
      size: 'small',
      runtime: 'bun',
      // rpx already fronts :80/:443 on the shared box. Both signals are set so
      // the deploy never stands up nginx + certbot, which would race it.
      webServer: 'rpx',
      proxy: {
        engine: 'rpx',
        // Emits this tenant's own cert units (`rpx-cert-renew-home-lang.*`)
        // rather than leaving these hosts on the box's fallback certificate.
        onDemandTls: true,
        onDemandTlsEmail: 'hello@stacksjs.com',
      },
    },

    // home-lang.org is a Porkbun zone. With the provider set, the deploy
    // reconciles the A records for every site domain to the box IP, so the
    // zone can never drift back to Porkbun's parking host. Credentials come
    // from PORKBUN_API_KEY / PORKBUN_SECRET_KEY at deploy time.
    dns: {
      provider: 'porkbun',
      domain: 'home-lang.org',
    },
  },

  sites: {
    // server-static: built locally, shipped to /var/www/home-lang-site/current,
    // served by the shared rpx gateway's file_server. No `start`/`port`.
    //
    // `www.home-lang.org` is NOT declared here: ts-cloud's autoWww adds the
    // redirect to the apex for every two-label domain, and skips the
    // three-label `docs.` host, which is exactly the shape wanted.
    site: {
      deploy: 'server',
      domain: 'home-lang.org',
      // BunPress renders into a `.bunpress` SUBDIRECTORY of `--outdir`, so the
      // site root is that subdirectory, not the outdir. Pointing at the parent
      // ships a release whose pages are all one level too deep and 404s every
      // URL; ts-cloud now refuses that at package time and names this path.
      root: 'dist/docs/.bunpress',
      // `bunpress` has no runnable bin on npm — the engine these docs are
      // written against is @stacksjs/bunpress. Pinned so a deploy is
      // reproducible; the build wipes its own outdir, so no clean step here.
      build: 'bunx --bun @stacksjs/bunpress@0.2.4 build --dir ./docs --outdir ./dist/docs',
      // Extensionless doc URLs resolve to <path>/index.html.
      pathRewriteStyle: 'directory',
    },

    // The docs used to be a site of their own on this host. They are a path on
    // the apex now, so the host becomes a redirect: it ships nothing, keeps its
    // place in the gateway's TLS set, and `preservePath` carries the rest of
    // the URL over, so `docs.home-lang.org/guide/x` lands on
    // `home-lang.org/docs/guide/x`.
    docs: {
      domain: 'docs.home-lang.org',
      redirect: { to: 'https://home-lang.org/docs', status: 301, preservePath: true },
    },
  },
}

export default config
