import os

os.environ.setdefault('FLASK_SECRET_KEY', 'test-only')
os.environ.setdefault('LDAP_URL', 'ldap://10.10.10.13:389')
os.environ.setdefault('LDAP_BASE_DN', 'OU=SOC-Lab,DC=lab,DC=test')
os.environ.setdefault('LDAP_REQUIRED_GROUP', 'CN=SOC-Web-Users,OU=SOC-Lab,DC=lab,DC=test')

from app import normalize_username


assert normalize_username('alice') == ('alice', 'alice@lab.test')
assert normalize_username('alice@LAB.TEST') == ('alice', 'alice@lab.test')
assert normalize_username('alice@example.com') is None
assert normalize_username('alice)(objectClass=*)') is None
