-- Prepare Tarantool space for the benchmark.
-- Run inside Tarantool console as an admin/user with DDL permissions.
-- The benchmark can then be started with --tarantool-no-ddl.

box.cfg{}

local space_name = os.getenv('TARANTOOL_SPACE') or 'kv'
local app_user = os.getenv('TARANTOOL_USER') or 'app'
local app_password = os.getenv('TARANTOOL_PASSWORD') or 'app'

if box.schema.user.exists(app_user) == false then
    box.schema.user.create(app_user, {
        password = app_password,
        if_not_exists = true,
    })
end

local s = box.space[space_name]
if s == nil then
    s = box.schema.space.create(space_name, {
        if_not_exists = true,
        engine = 'memtx',
    })
end

s:format({
    {name = 'key', type = 'string'},
    {name = 'value', type = 'string'},
})

if s.index.primary == nil then
    s:create_index('primary', {
        type = 'TREE',
        parts = {{field = 'key', type = 'string'}},
        if_not_exists = true,
    })
end

box.schema.user.grant(app_user, 'read,write', 'space', space_name, {
    if_not_exists = true,
})

print(('Prepared space %q and granted read,write to user %q'):format(space_name, app_user))
