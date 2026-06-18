# omnicore_ai

A Flutter AI workspace with Groq for conversational generation and SerpApi for
live retrieval.

## AI provider configuration

Groq is the only conversational model provider. SerpApi is used only as the
retrieval/search layer. Local development defaults to the Node backend on
`http://localhost:3000`, so the browser never receives provider secrets.

### Local backend

The local backend lives in `backend` and exposes:

- `GET /health` for non-secret health checks
- `GET /config/status` for non-secret configuration checks
- `POST /config/keys` for local key updates
- `POST /groq` for Groq chat completions
- `POST /v1/retrieval` for live SerpApi search

Local development:

```powershell
cd backend
npm install
npm start
```

In another terminal:

```powershell
flutter run -d chrome
```

Use the developer-only configuration panel to save Groq and SerpApi keys into
`backend/.env`. Full key values are never displayed by the UI.

Optional local backend override:

- `OMNICORE_BACKEND_URL`

### SerpApi retrieval via Cloudflare Worker

The legacy retrieval proxy still lives in `cloudflare/sarf-proxy` and exposes
`POST /v1/retrieval`.

Production Worker deploy:

```powershell
cd cloudflare\sarf-proxy
npx wrangler secret put SERPAPI_API_KEY
npm run deploy
```

Production Flutter build:

```powershell
flutter build web `
  --dart-define=SERPAPI_PROXY_BASE_URL=https://omnicore-serpapi-proxy.YOUR_ACCOUNT.workers.dev
```

Optional SerpApi frontend overrides:

- `SERPAPI_PROXY_BASE_URL`
- `SERPAPI_PROXY_RETRIEVAL_ENDPOINT`
- `SERPAPI_LOCAL_PROXY_BASE_URL`
- `SERPAPI_USE_LOCAL_PROXY_FALLBACK`

### Groq generation

The recommended web path is the local backend:

```powershell
cd backend
npm start
```

Optional Groq override:

- `GROQ_API_ENDPOINT`

Optional routing override:

- `OMNICORE_AI_PROVIDER=auto|groq`

For production Web deployments, any provider secret passed to Flutter can be
read by browser clients. Keep Groq and SerpApi secrets on trusted backends.

## AI OS foundation

The router now runs through an orchestration layer:

1. Detects whether a prompt needs retrieval, URL context, verification, or
   current information.
2. Runs the SerpApi retrieval tool through the configured Worker retrieval
   endpoint.
3. Adds live search context and relevant saved memories to the Groq prompt.
4. Streams the final Groq response with the existing Send/Stop cancellation
   path.

Memory commands:

- `Remember this: ...`
- `Forget this: ...`

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
