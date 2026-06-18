# OmniCore SerpApi Retrieval Worker

This Worker keeps SerpApi credentials out of Flutter Web builds. The Flutter
app calls this proxy, and the Worker injects `SERPAPI_API_KEY` server-side
before forwarding retrieval requests to SerpApi.

## Endpoints

- `POST /v1/retrieval`
  - Calls SerpApi search and returns `{ answer, summary, results }`.
- `GET /health`
  - Returns basic configuration health without exposing secrets.

## Local development

```powershell
cd cloudflare\sarf-proxy
npm install
npx wrangler secret put SERPAPI_API_KEY
npm run dev
```

Then run Flutter with the local proxy fallback:

```powershell
flutter run -d chrome --dart-define=SERPAPI_USE_LOCAL_PROXY_FALLBACK=true
```

The fallback points at `http://localhost:8787` by default. Override it with:

```powershell
flutter run -d chrome `
  --dart-define=SERPAPI_USE_LOCAL_PROXY_FALLBACK=true `
  --dart-define=SERPAPI_LOCAL_PROXY_BASE_URL=http://localhost:8787
```

## Production deploy

1. Update `ALLOWED_ORIGINS` in `wrangler.toml` to your Firebase Hosting domains.
   Local wildcards such as `http://localhost:*` are meant for development.
2. Save the SerpApi key as a Worker secret:

```powershell
npx wrangler secret put SERPAPI_API_KEY
```

3. Deploy:

```powershell
npm run deploy
```

4. Build Flutter with the deployed Worker URL:

```powershell
flutter build web `
  --dart-define=SERPAPI_PROXY_BASE_URL=https://omnicore-serpapi-proxy.YOUR_ACCOUNT.workers.dev
```

Do not pass `SERPAPI_API_KEY` to Flutter. Provider keys belong only in Worker
secrets.
