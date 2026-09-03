-- Snap db_version back to stock max when IdleOT numbered 65–72 already ran.
-- Crystal only applies N.lua when N > db_version; leaving 72 would skip future stock 65+.
local STOCK_MAX_AT_CUTOVER = 64

local m = Migration("20240830000000_cutover_numbered_product_migrations")
function m:onExecute()
	local r = db.storeQuery("SELECT `value` FROM `server_config` WHERE `config` = 'db_version'")
	if not r then
		return
	end
	local v = tonumber(Result.getString(r, "value")) or 0
	Result.free(r)
	if v >= 65 and v < 10000 then
		db.query(string.format(
			"UPDATE `server_config` SET `value` = '%d' WHERE `config` = 'db_version'",
			STOCK_MAX_AT_CUTOVER
		))
		logger.info(
			"cutover: db_version {} → {} (product scripts now live in custom_migrations)",
			v,
			STOCK_MAX_AT_CUTOVER
		)
	end
end
m:register()
