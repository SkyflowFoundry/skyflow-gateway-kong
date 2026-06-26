-- kong.plugins.skyflow-deidentify.auth
--
-- Skyflow credential -> bearer token. Supports:
--   * api_key              (used directly as `Bearer <api_key>`)
--   * token                (static, used as-is)
--   * service_account_json (mint a short-lived token via RS256 JWT exchange)
--
-- Tokens are cached node-wide in kong.cache with a TTL of (expiresIn - skew),
-- and minted single-flight (mlcache uses lua-resty-lock under the hood) so a
-- burst of cold requests triggers exactly one mint. See docs/03 §3.2.
--
-- Reference skeleton: JWT signing + token exchange are sketched; wire them to
-- resty.openssl (preferred, bundled) or lua-resty-jwt during implementation.

local http  = require "resty.http"
local cjson = require "cjson.safe"

local kong = kong
local ngx  = ngx

local _M = {}

-- Stable cache key derived from the credential material (never the value in
-- logs). A hash keeps the key bounded and avoids leaking secrets via cache keys.
local function cache_key(conf)
  local c = conf.credentials
  local material = c.api_key or c.token or c.service_account_json or ""
  return "skyflow:token:" .. ngx.md5(conf.cluster_id .. ":" .. material)
end

-- Build + RS256-sign the SA assertion and exchange it for an access token.
-- Returns token, ttl_seconds, err.
local function mint_service_account_token(conf)
  local sa = cjson.decode(conf.credentials.service_account_json)
  if not sa or not sa.tokenURI or not sa.privateKey then
    return nil, nil, "invalid service_account_json (need clientID, keyID, tokenURI, privateKey)"
  end

  -- TODO(impl): build JWT claims and RS256-sign with sa.privateKey.
  --   claims = { iss = sa.clientID, key = sa.keyID, aud = sa.tokenURI,
  --              sub = sa.clientID, exp = ngx.time() + 3600 }
  --   assertion = sign_rs256(claims, sa.privateKey)   -- resty.openssl / resty.jwt
  local assertion = "<signed-jwt>"  -- placeholder

  local httpc = http.new()
  httpc:set_timeout(conf.timeout_ms)
  local res, err = httpc:request_uri(sa.tokenURI, {
    method = "POST",
    headers = { ["Content-Type"] = "application/json" },
    body = cjson.encode({
      grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion  = assertion,
    }),
    ssl_verify = true,
  })
  if not res then return nil, nil, "token endpoint error: " .. tostring(err) end
  if res.status ~= 200 then
    return nil, nil, "token endpoint status " .. res.status
  end

  local payload = cjson.decode(res.body) or {}
  local tok = payload.accessToken or payload.access_token
  local ttl = (payload.expiresIn or payload.expires_in or 3600) - (conf.token_skew_seconds or 300)
  if not tok then return nil, nil, "token endpoint returned no access token" end
  return tok, math.max(ttl, 1)
end

-- Resolve a usable bearer token for the configured credential, cached.
-- Returns token, err.
function _M.get(conf)
  local c = conf.credentials

  -- Static credentials: no minting, but still represented as a bearer value.
  if c.api_key then return c.api_key end
  if c.token   then return c.token end

  -- Service account: cache the minted token; mint single-flight on miss.
  local key = cache_key(conf)
  local token, err = kong.cache:get(key, nil, function()
    local tok, ttl, merr = mint_service_account_token(conf)
    if not tok then
      -- returning an error makes mlcache NOT cache; negative caching avoided
      return nil, merr
    end
    -- second return value sets the per-entry TTL
    return tok, nil, ttl
  end)

  if not token then return nil, err or "failed to obtain Skyflow token" end
  return token
end

-- Force a refresh (used on a mid-flight 401). Invalidates then re-fetches.
function _M.refresh(conf)
  kong.cache:invalidate(cache_key(conf))
  return _M.get(conf)
end

-- Best-effort warm-up from the configure phase.
function _M.prewarm(conf)
  if conf.credentials.service_account_json then
    local _, err = _M.get(conf)
    if err then error(err) end
  end
end

return _M
