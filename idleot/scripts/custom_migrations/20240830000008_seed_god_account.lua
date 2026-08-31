-- IdleOT custom migration (was numbered core *.product).
-- Ensure sample god account matches product login (god@example.com / god).
-- Upstream schema seeds name/email as god / @god; IdleOT AAC + docs use god@example.com.
-- Idempotent: only rewrites the well-known sample account id=1 when still upstream-shaped.

local m = Migration("20240830000008_seed_god_account")
function m:onExecute()
	db.query([[
		UPDATE `accounts`
		SET `name` = 'god', `email` = 'god@example.com'
		WHERE `id` = 1
			AND (`email` = '@god' OR `email` = 'god@example.com' OR `name` = 'god')
	]])
	return true
end
m:register()
