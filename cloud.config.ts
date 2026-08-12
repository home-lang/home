import type { CloudConfig } from '@stacksjs/ts-cloud'

/**
 * ts-cloud deployment config for the Home documentation site.
 *
 * Ships the BunPress build of `docs/` to the shared Stacks Hetzner box as
 * `home-lang.org` and `docs.home-lang.org`. Both hosts serve the same build:
 * the apex is the site, and `docs.` is kept because every og:url and outbound
 * link in `.config/docs.ts` already points at it.
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
    // server-static: built locally, shipped to /var/www/home-lang-docs/current,
    // served by the shared rpx gateway's file_server. No `start`/`port`.
    //
    // `www.home-lang.org` is NOT declared here: ts-cloud's autoWww adds the
    // redirect to the apex for every two-label domain, and skips the
    // three-label `docs.` host, which is exactly the shape wanted.
    //
    // Both hosts serve the same build, but as TWO sites rather than one site
    // with `domain: [...]`. ts-cloud routes an array fine, then its
    // post-deploy DNS/certificate step slugifies `site.domain` with
    // `.replace(...)` and throws `.replace is not a function` on an array. The
    // release ships before that step, so the symptom is a deploy that
    // publishes correctly and still exits 1.
    //
    // The build runs once, on `site`. `docs` reuses the same `root`, so it
    // needs no build of its own.
    site: {
      deploy: 'server',
      root: 'dist/docs',
      domain: 'home-lang.org',
      // The package scripts call bare `bunpress`, which has no runnable bin on
      // npm; the engine these docs are written against is @stacksjs/bunpress,
      // and it renders into a `.bunpress` SUBDIRECTORY of --outdir. Shipping
      // the parent therefore ships an empty release. `scripts/deploy-docs.ts`
      // flattens that subdirectory into `dist/docs` and then deploys, which is
      // why the build step is dropped on that path. Always deploy with it.
      build: process.env.HOME_LANG_PREBUILT ? undefined : 'bun scripts/deploy-docs.ts --build-only',
      // Extensionless doc URLs resolve to <path>/index.html.
      pathRewriteStyle: 'directory',
    },

    docs: {
      deploy: 'server',
      root: 'dist/docs',
      domain: 'docs.home-lang.org',
      pathRewriteStyle: 'directory',
    },
  },
}

export default config
