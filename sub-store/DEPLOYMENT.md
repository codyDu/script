# Sub-Store Cloudflare deployment

- Adapter: https://github.com/SaintWe/Sub-Store-Workers
- Adapter commit: d3eacc88b8a288d484bb7ba7daf7c8c075409677 (multi-tenant)
- Official backend: sub-store-org/Sub-Store, version 2.36.0
- Worker: sub-store
- Dashboard: https://sub-store.125000.xyz/dashboard/
- Fallback: https://sub-store.imcodyd.workers.dev/dashboard/
- Storage: SQLite Durable Objects, IndexDO and UserDO, migration v1
- Cron: 0 */6 * * * (UTC)

The upstream adapter was built without service-source changes. Backend 2.42.5 fails its current environment-detection patch checks; keep 2.36.0 pinned until compatibility is verified.

Reproduce the build using Node.js 22.20+ and pnpm:

```sh
git clone https://github.com/SaintWe/Sub-Store-Workers.git
cd Sub-Store-Workers
git checkout d3eacc88b8a288d484bb7ba7daf7c8c075409677
cp wrangler.toml.example wrangler.toml
# Remove the JWT_SECRET placeholder from [vars]. Supply JWT_SECRET as a Worker secret when deploying.
pnpm install
SUBSTORE_VERSION=2.36.0 pnpm run fetch:substore
pnpm run build:workers
```

Deployment was performed through the authorized Cloudflare connection. The GitHub repository connection exists, but no Builds trigger or automatic update has been enabled: the account has no reusable Builds token. No Cloudflare token, administrator password, private backend path, node credential, or subscription URL belongs in this public repository.

Use the dashboard to open the official Sub-Store frontend. Nodes and hosted files are stored in Durable Objects, not GitHub. Export ClashMeta for Mihomo and ShadowRocket for Shadowrocket. Actual client imports require real node subscriptions and separate verification.
