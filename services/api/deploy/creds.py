import json, os, sys
c = json.load(open(os.path.expanduser('~/.aliyun/config.json')))
want = sys.argv[1] if len(sys.argv) > 1 else c.get('current')
p = next(p for p in c['profiles'] if p['name'] == want)
print(p['access_key_id'] if sys.argv[2] == 'id' else p['access_key_secret'])
