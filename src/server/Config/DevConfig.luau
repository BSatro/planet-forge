--!strict
-- DevConfig — owner: Developer B. Developer test commands. They are NEVER available when the data
-- environment is "production" regardless of these values (DevCommandService checks the environment).

local DevConfig = {}

DevConfig.ENABLED = true -- master switch for non-production environments
DevConfig.ALLOW_EXPERIENCE_OWNER = true -- in a live TEST experience, the owning user may use commands
DevConfig.DEV_USER_IDS = {} :: { number } -- extra testers allowed in a live TEST experience

DevConfig.MAX_GRANT = 100_000 -- max amount per grant command
DevConfig.MAX_FAIL_INJECT = 20 -- max injected mock datastore failures per command

return DevConfig
