-- kong.plugins.skyflow-deidentify.mapping
--
-- Request-scoped store of {token -> {value, entity}} captured during access
-- and consumed during response. Lives ONLY in kong.ctx.plugin for the life of
-- one request -- never logged, never written to kong.cache, never shared
-- across requests or workers. See docs/03 §3.6 and docs/07 (no-PII-at-rest).

local _M = {}

-- Store the De-identify entities[] result on the request context.
-- `entities` is the list returned by client.deidentify():
--   { { token=, value=, entity=, scores= }, ... }
function _M.put(ctx, entities)
  local by_token, counts = {}, {}
  for _, e in ipairs(entities or {}) do
    by_token[e.token] = { value = e.value, entity = e.entity }
    counts[e.entity] = (counts[e.entity] or 0) + 1
  end
  ctx.mapping = { by_token = by_token, counts = counts }
  return ctx.mapping
end

-- Look up a single token's original value (mapping_only re-identify).
function _M.value_of(ctx, token)
  local m = ctx.mapping
  local e = m and m.by_token and m.by_token[token]
  return e and e.value or nil
end

-- Entity class for a token (drives entity_treatment decisions).
function _M.entity_of(ctx, token)
  local m = ctx.mapping
  local e = m and m.by_token and m.by_token[token]
  return e and e.entity or nil
end

-- Detected-entity counts by type (for the log phase). Counts only -- no values.
function _M.counts(ctx)
  return ctx.mapping and ctx.mapping.counts or {}
end

return _M
