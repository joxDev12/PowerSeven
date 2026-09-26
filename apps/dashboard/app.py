import os
import re
import ssl
from urllib.parse import urlparse

from flask import Flask, render_template_string, request, redirect, url_for, session
from ldap3 import ALL, Connection, Server, SUBTREE, Tls
from ldap3.utils.conv import escape_filter_chars

app = Flask(__name__)
app.secret_key = os.environ['FLASK_SECRET_KEY']
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_SAMESITE='Lax',
)

USERNAME_RE = re.compile(r'^[A-Za-z0-9._-]{1,64}$')


def normalize_username(value):
    value = (value or '').strip()
    if '@' in value:
        local, domain = value.rsplit('@', 1)
        if domain.casefold() != 'lab.test':
            return None
    else:
        local = value

    if not USERNAME_RE.fullmatch(local):
        return None
    return local, f'{local}@lab.test'


def ldap_server():
    parsed = urlparse(os.environ['LDAP_URL'])
    if parsed.scheme not in {'ldap', 'ldaps'} or not parsed.hostname:
        raise ValueError('LDAP_URL must be ldap:// or ldaps://')
    if parsed.username or parsed.password or parsed.path not in ('', '/'):
        raise ValueError('LDAP_URL must not contain credentials or a path')

    kwargs = {
        'host': parsed.hostname,
        'port': parsed.port or (636 if parsed.scheme == 'ldaps' else 389),
        'use_ssl': parsed.scheme == 'ldaps',
        'get_info': ALL,
        'connect_timeout': 4,
    }
    if parsed.scheme == 'ldaps':
        kwargs['tls'] = Tls(
            validate=ssl.CERT_REQUIRED,
            version=ssl.PROTOCOL_TLS_CLIENT,
            ca_certs_file='/etc/ssl/certs/ca-certificates.crt',
        )
    return Server(**kwargs)


LOGIN_TEMPLATE = """<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Accesso - Portale Aziendale</title>
<style>
*{box-sizing:border-box}
body{
    margin:0;
    min-height:100vh;
    display:flex;
    align-items:center;
    justify-content:center;
    font-family:Arial,sans-serif;
    background:linear-gradient(135deg,#0f172a,#1e3a8a);
    color:#172033
}
.card{
    width:min(420px,92%);
    background:white;
    border-radius:18px;
    padding:38px;
    box-shadow:0 20px 50px rgba(0,0,0,.25)
}
.logo{
    width:52px;
    height:52px;
    border-radius:14px;
    background:#2563eb;
    color:white;
    display:flex;
    align-items:center;
    justify-content:center;
    font-size:24px;
    font-weight:bold;
    margin-bottom:22px
}
h1{margin:0 0 8px}
.subtitle{color:#64748b;margin-bottom:28px}
label{font-weight:600;font-size:14px}
input{
    width:100%;
    padding:12px;
    margin:7px 0 18px;
    border:1px solid #cbd5e1;
    border-radius:9px;
    font-size:15px
}
button{
    width:100%;
    padding:12px;
    border:0;
    border-radius:9px;
    background:#2563eb;
    color:white;
    font-size:15px;
    font-weight:bold;
    cursor:pointer
}
button:hover{background:#1d4ed8}
.error{
    background:#fee2e2;
    color:#991b1b;
    padding:11px;
    border-radius:8px;
    margin-bottom:18px
}
</style>
</head>
<body>
<div class="card">
    <div class="logo">IT</div>
    <h1>Portale Aziendale</h1>
    <div class="subtitle">Accedi con il tuo account aziendale</div>

    {% if error %}
    <div class="error">{{ error }}</div>
    {% endif %}

    <form method="post">
        <label>Username</label>
        <input name="username" required autocomplete="username"
               placeholder="nome.utente">

        <label>Password</label>
        <input type="password" name="password" required
               autocomplete="current-password"
               placeholder="Password">

        <button type="submit">Accedi al portale</button>
    </form>
</div>
</body>
</html>"""


# Elenco statico di collegamenti: il portale non presume che i servizi abbiano SSO.
SERVICES = [
    {'name': 'Forgejo', 'host': 'git.lab.test', 'url': 'https://git.lab.test',
     'description': 'Repository, codice e collaborazione.', 'vps': 'VPS 9',
     'category': 'Sviluppo', 'icon': 'git', 'tone': 'coral'},
    {'name': 'Stirling PDF', 'host': 'pdf.lab.test', 'url': 'https://pdf.lab.test',
     'description': 'Converti, unisci e organizza i documenti.', 'vps': 'VPS 9',
     'category': 'Documenti', 'icon': 'pdf', 'tone': 'rose'},
    {'name': 'AdGuard Home', 'host': 'adguard.lab.test', 'url': 'https://adguard.lab.test',
     'description': 'DNS interno e gestione dei filtri.', 'vps': 'VPS 9',
     'category': 'Rete', 'icon': 'shield', 'tone': 'emerald'},
    {'name': 'Nextcloud', 'host': 'cloud.lab.test', 'url': 'https://cloud.lab.test',
     'description': 'File e collaborazione nel cloud aziendale.', 'vps': 'VPS 10',
     'category': 'Cloud', 'icon': 'cloud', 'tone': 'sky'},
    {'name': 'Pterodactyl', 'host': 'panel.lab.test', 'url': 'https://panel.lab.test',
     'description': 'Pannello dei server di gioco del laboratorio.', 'vps': 'VPS 11',
     'category': 'Game lab', 'icon': 'game', 'tone': 'violet'},
    {'name': 'Wazuh Dashboard', 'host': 'wazuh.lab.test', 'url': 'https://wazuh.lab.test',
     'description': 'Monitoraggio, eventi e sicurezza SOC.', 'vps': 'VPS 4',
     'category': 'Sicurezza', 'icon': 'radar', 'tone': 'indigo'},
]


DASHBOARD_TEMPLATE = """<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light">
<title>Dashboard servizi · Portale SOC</title>
<style>
:root{font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
  color:#15223c;background:#f4f7fc;font-synthesis:none}
*{box-sizing:border-box}
body{margin:0;min-height:100vh}
a{color:inherit;text-decoration:none}
a:focus-visible{outline:3px solid #3478f6;outline-offset:5px}
.shell{display:grid;grid-template-columns:254px minmax(0,1fr);min-height:100vh}
.sidebar{background:#101b34;color:#f9fbff;padding:31px 20px 26px;display:flex;flex-direction:column;
  border-right:1px solid #263656}
.brand{display:flex;align-items:center;gap:13px;padding:4px 8px 34px}
.brand-mark{width:43px;height:43px;display:grid;place-items:center;border-radius:14px;
  background:linear-gradient(145deg,#57a8ff,#285add);box-shadow:0 8px 22px #0a2b6b66;color:white}
.brand-mark svg{width:23px;height:23px;fill:none;stroke:currentColor;stroke-width:2.2}
.brand strong{display:block;font-size:16px;letter-spacing:-.35px}
.brand span{display:block;margin-top:3px;color:#a7bad8;font-size:11px;letter-spacing:1.2px;font-weight:750}
.nav-label{font-size:10px;letter-spacing:1.6px;color:#7c91b3;font-weight:800;padding:0 16px;margin:12px 0 11px}
.nav-link{display:flex;align-items:center;gap:12px;padding:14px 16px;border:1px solid #4d7cff55;
  background:linear-gradient(90deg,#274a86,#20365c);border-radius:12px;color:white;font-size:13px;font-weight:700}
.nav-link svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:2}
.sidebar-bottom{margin-top:auto;padding:22px 8px 0}
.net-box{padding:15px;border-radius:13px;border:1px solid #2d4164;background:#182845}
.net-box .dot{width:8px;height:8px;border-radius:100%;display:inline-block;background:#6eebbd;margin-right:7px}
.net-box strong{font-size:12px}
.net-box p{color:#a6b8d5;font-size:11px;line-height:1.6;margin:6px 0 0}
.sidebar-user{display:flex;gap:10px;align-items:center;margin-top:24px}
.avatar{width:38px;height:38px;flex:0 0 38px;border-radius:12px;background:#2c4b80;
  display:grid;place-items:center;color:#e9f3ff;font-size:16px;font-weight:800}
.sidebar-user strong{font-size:12px;display:block;max-width:146px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sidebar-user small{display:block;color:#aabbd8;font-size:11px;margin-top:3px}
.main{min-width:0;padding:0 clamp(20px,5vw,74px) 52px}
.topbar{display:flex;justify-content:space-between;align-items:center;gap:16px;min-height:90px;border-bottom:1px solid #e4eaf3}
.breadcrumb{display:flex;align-items:center;gap:9px;color:#7b8aa2;font-size:13px}
.breadcrumb b{color:#20314d}
.top-actions{display:flex;gap:18px;align-items:center}
.portal-pill{border:1px solid #dce6f4;border-radius:100px;background:#fff;padding:9px 13px;
  font-size:11px;font-weight:750;color:#446188;white-space:nowrap}
.signout{color:#284f95;font-size:12px;font-weight:750;display:flex;align-items:center;gap:7px}
.signout svg{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:2}
.content{max-width:1270px;margin:0 auto}
.eyebrow{font-weight:850;font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#3170d7}
.hero{position:relative;overflow:hidden;display:flex;align-items:center;justify-content:space-between;
  gap:28px;padding:clamp(29px,4vw,49px);margin-top:34px;border-radius:23px;color:white;
  background:linear-gradient(114deg,#182e5b 0%,#234c98 55%,#416fd5 100%);
  box-shadow:0 17px 45px #1a458826}
.hero:before{content:"";position:absolute;width:350px;height:350px;border-radius:50%;right:-105px;top:-180px;
  border:58px solid #ffffff13;pointer-events:none}
.hero:after{content:"";position:absolute;width:180px;height:180px;border-radius:50%;right:165px;bottom:-150px;
  background:#7aa7ff28;pointer-events:none}
.hero-copy{position:relative;z-index:1}
.hero-kicker{font-size:11px;font-weight:750;letter-spacing:1.8px;text-transform:uppercase;color:#b9d6ff}
.hero h1{font-size:clamp(27px,3vw,41px);line-height:1.15;letter-spacing:-1.6px;margin:13px 0 14px;font-weight:850}
.hero p{font-size:14px;color:#d6e5ff;line-height:1.7;margin:0;max-width:600px}
.hero-art{flex:0 0 132px;width:132px;height:132px;display:grid;place-items:center;border-radius:30px;
  border:1px solid #ffffff42;background:#ffffff19;box-shadow:inset 0 1px #ffffff35;transform:rotate(-6deg)}
.hero-art svg{width:79px;height:79px;stroke:#e8f3ff;stroke-width:1.55;fill:none}
.section-head{display:flex;justify-content:space-between;align-items:end;gap:15px;margin:42px 0 21px}
.section-head h2{font-size:24px;letter-spacing:-.8px;margin:8px 0 0;font-weight:850}
.section-head p{color:#7889a2;font-size:12px;margin:0 0 4px}
.service-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:19px}
.service-card{min-width:0;min-height:235px;background:white;display:flex;flex-direction:column;
  border:1px solid #e4eaf3;border-radius:17px;box-shadow:0 5px 18px #23375809;
  overflow:hidden;transition:transform .2s ease,box-shadow .2s ease,border-color .2s ease}
.service-card:hover{transform:translateY(-4px);box-shadow:0 19px 38px #294a801c;border-color:#b9cef0}
.service-body{flex:1;padding:22px 22px 19px}
.service-top{display:flex;align-items:start;justify-content:space-between;gap:8px;margin-bottom:19px}
.service-icon{width:51px;height:51px;border-radius:15px;display:grid;place-items:center}
.service-icon svg{width:26px;height:26px;fill:none;stroke:currentColor;stroke-width:2;
 stroke-linecap:round;stroke-linejoin:round}
.coral{background:#fff0eb;color:#e35231}.rose{background:#fff0f0;color:#da4651}
.emerald{background:#e8f8ef;color:#219465}.sky{background:#e8f3ff;color:#1978cc}
.violet{background:#f1ecff;color:#7150cf}.indigo{background:#eaf0ff;color:#3566db}
.vps{padding:7px 10px;border-radius:100px;background:#f0f5ff;color:#4770b4;
  font-size:10px;font-weight:850;white-space:nowrap}
.category{font-size:10px;font-weight:800;text-transform:uppercase;letter-spacing:1.2px;color:#8a99af;margin:0 0 6px}
.service-card h3{font-size:18px;letter-spacing:-.5px;margin:0 0 7px}
.description{font-size:12px;line-height:1.55;color:#73839b;margin:0 0 11px;min-height:36px}
.domain{color:#536b94;font-size:12px;font-weight:650;overflow-wrap:anywhere}
.card-bottom{border-top:1px solid #edf1f7;display:flex;align-items:center;justify-content:space-between;
  padding:15px 22px;color:#2365ca;font-weight:800;font-size:12px;background:#fcfdff}
.card-bottom svg{width:16px;height:16px;stroke:currentColor;fill:none;stroke-width:2;transition:transform .2s ease}
.service-card:hover .card-bottom svg{transform:translateX(3px)}
.notice{display:flex;gap:12px;align-items:start;margin-top:28px;padding:17px 19px;border-radius:13px;
  background:#ebf2fc;border:1px solid #dce7f6;color:#4c6485;font-size:12px;line-height:1.65}
.notice svg{flex:0 0 18px;width:18px;height:18px;margin-top:1px;stroke:#4f7bbd;stroke-width:2;fill:none}
.footer{padding:29px 0 0;display:flex;justify-content:space-between;gap:12px;color:#91a0b5;font-size:11px}
@media(max-width:1150px){.service-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.hero-art{width:100px;height:100px;flex-basis:100px}.hero-art svg{width:60px;height:60px}}
@media(max-width:760px){.shell{display:block}.sidebar{padding:14px 20px}.brand{padding:0}.sidebar .nav-label,.sidebar .nav-link,.sidebar-bottom{display:none}
 .main{padding:0 20px 30px}.topbar{min-height:72px}.hero{margin-top:23px;padding:28px}.hero-art{display:none}.section-head{margin-top:29px}}
@media(max-width:520px){.service-grid{grid-template-columns:1fr}.topbar .portal-pill{display:none}
 .section-head{display:block}.section-head p{margin-top:8px}.hero h1{letter-spacing:-.8px}.footer{display:block}.footer span{display:block;margin-bottom:7px}}
@media(prefers-reduced-motion:reduce){.service-card,.card-bottom svg{transition:none}.service-card:hover{transform:none}}
</style>
</head>
<body>
<!-- Icone SVG locali: nessun CDN o libreria esterna necessaria. -->
<svg xmlns="http://www.w3.org/2000/svg" style="position:absolute;width:0;height:0;overflow:hidden" aria-hidden="true">
 <symbol id="ic-overview" viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></symbol>
 <symbol id="ic-git" viewBox="0 0 24 24"><circle cx="7" cy="5" r="2"/><circle cx="17" cy="7" r="2"/><circle cx="17" cy="19" r="2"/><path d="M7 7v9a3 3 0 0 0 3 3h5M7 11a4 4 0 0 0 4-4h4"/></symbol>
 <symbol id="ic-pdf" viewBox="0 0 24 24"><path d="M6 2h8l5 5v15H6a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM14 2v6h5M8 13h8M8 17h8"/></symbol>
 <symbol id="ic-shield" viewBox="0 0 24 24"><path d="m12 2 9 4v5c0 6-4 10-9 12-5-2-9-6-9-12V6l9-4zM8 12l3 3 5-6"/></symbol>
 <symbol id="ic-cloud" viewBox="0 0 24 24"><path d="M7 18a5 5 0 0 1-1-9.9A7 7 0 0 1 19 10a4 4 0 0 1-1 8H7z"/></symbol>
 <symbol id="ic-game" viewBox="0 0 24 24"><path d="M7 8h10a5 5 0 0 1 4.8 4l1 5a3 3 0 0 1-4.8 3l-3-3H9l-3 3a3 3 0 0 1-4.8-3l1-5A5 5 0 0 1 7 8zM7 11v5M4.5 13.5h5M16 12h.01M19 15h.01"/></symbol>
 <symbol id="ic-radar" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><path d="M12 12l7-7M12 3v2M12 19v2M3 12h2M19 12h2"/></symbol>
 <symbol id="ic-arrow" viewBox="0 0 24 24"><path d="M5 12h14m-6-6 6 6-6 6"/></symbol>
 <symbol id="ic-logout" viewBox="0 0 24 24"><path d="M10 4H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h5M14 7l5 5-5 5M8 12h11"/></symbol>
 <symbol id="ic-info" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><path d="M12 11v6M12 7v.5"/></symbol>
</svg>
<div class="shell">
 <aside class="sidebar" aria-label="Navigazione del portale">
  <div class="brand"><div class="brand-mark"><svg aria-hidden="true"><use href="#ic-overview"/></svg></div>
   <div><strong>SOC Portal</strong><span>AZIENDA DEMO</span></div></div>
  <div class="nav-label">WORKSPACE</div>
  <a class="nav-link" href="{{ url_for('home') }}" aria-current="page"><svg aria-hidden="true"><use href="#ic-overview"/></svg> Panoramica</a>
  <div class="sidebar-bottom"><div class="net-box"><strong><span class="dot"></span>Servizi intranet</strong>
   <p>Collegamenti ai domini interni del laboratorio.</p></div>
   <div class="sidebar-user"><span class="avatar" aria-hidden="true">{{ display_name[:1]|upper }}</span>
    <div><strong title="{{ display_name }}">{{ display_name }}</strong><small>{{ role }}</small></div></div>
  </div>
 </aside>
 <div class="main">
  <header class="topbar"><div class="breadcrumb">Workspace <span aria-hidden="true">/</span> <b>Dashboard</b></div>
   <div class="top-actions"><span class="portal-pill">INTRANET · LAB.TEST</span>
    <a class="signout" href="{{ url_for('logout') }}"><svg aria-hidden="true"><use href="#ic-logout"/></svg> Esci</a></div>
  </header>
  <main class="content">
   <section class="hero" aria-labelledby="welcome-title"><div class="hero-copy">
    <div class="hero-kicker">Il tuo spazio di lavoro</div>
    <h1 id="welcome-title">Bentornato, {{ display_name }}.</h1>
    <p>Tutti gli strumenti del laboratorio in un unico posto. Scegli un servizio per aprire direttamente il suo dominio aziendale.</p>
   </div><div class="hero-art" aria-hidden="true"><svg><use href="#ic-overview"/></svg></div></section>
   <section aria-labelledby="services-title">
    <div class="section-head"><div><span class="eyebrow">ACCESSO RAPIDO</span><h2 id="services-title">Servizi aziendali</h2></div>
     <p>{{ services|length }} collegamenti disponibili</p></div>
    <div class="service-grid">
    {% for service in services %}
     <a class="service-card" href="{{ service.url }}" aria-label="Apri {{ service.name }}: {{ service.host }}">
      <div class="service-body"><div class="service-top"><span class="service-icon {{ service.tone }}">
       <svg aria-hidden="true"><use href="#ic-{{ service.icon }}"/></svg></span>
       <span class="vps">{{ service.vps }}</span></div>
       <p class="category">{{ service.category }}</p><h3>{{ service.name }}</h3>
       <p class="description">{{ service.description }}</p><span class="domain">{{ service.host }}</span>
      </div><div class="card-bottom">Apri servizio <svg aria-hidden="true"><use href="#ic-arrow"/></svg></div>
     </a>
    {% endfor %}
    </div>
   </section>
   <div class="notice" role="note"><svg aria-hidden="true"><use href="#ic-info"/></svg>
    <div>Questa pagina raccoglie i collegamenti: l'accesso ai singoli servizi dipende dai rispettivi permessi e potrebbe richiedere un login separato.</div></div>
   <footer class="footer"><span>SOC Lab · Portale aziendale</span><span>Ambiente didattico · Risorse interne</span></footer>
  </main>
 </div>
</div>
</body>
</html>"""


def authenticate_ldap(username, password):
    normalized = normalize_username(username)
    if not normalized or not password or len(password) > 1024:
        return None

    search_username, ldap_user = normalized
    conn = None

    try:
        server = ldap_server()
        conn = Connection(
            server,
            user=ldap_user,
            password=password,
            auto_bind=False,
            receive_timeout=4,
        )
        if not conn.bind():
            return None

        search_filter = (
            '(&(objectCategory=person)(objectClass=user)(sAMAccountName=%s))'
            % escape_filter_chars(search_username)
        )

        conn.search(
            search_base=os.environ['LDAP_BASE_DN'],
            search_filter=search_filter,
            search_scope=SUBTREE,
            attributes=[
                'sAMAccountName',
                'userPrincipalName',
                'displayName',
                'mail',
                'memberOf',
                'userAccountControl',
            ]
        )

        if len(conn.entries) != 1:
            return None

        entry = conn.entries[0]
        groups = [str(x) for x in entry['memberOf'].values] if 'memberOf' in entry else []

        if os.environ['LDAP_REQUIRED_GROUP'].casefold() not in {
            group.casefold() for group in groups
        }:
            return None
        if 'userAccountControl' in entry and int(entry['userAccountControl'].value) & 2:
            return None

        def value(name, fallback=''):
            if name not in entry or entry[name].value is None:
                return fallback
            return str(entry[name].value)

        data = {
            'username': value('sAMAccountName', search_username),
            'user_principal_name': value('userPrincipalName', ldap_user),
            'display_name': value('displayName', search_username),
            'email': value('mail'),
            'member_of': groups,
        }
        return data

    except Exception:
        return None
    finally:
        if conn is not None:
            conn.unbind()


@app.get('/health')
def health():
    return 'OK', 200


@app.route('/login', methods=['GET', 'POST'])
def login():

    if request.method == 'GET':
        if 'username' in session:
            return redirect(url_for('home'))
        return render_template_string(LOGIN_TEMPLATE)

    username = request.form.get('username', '')
    password = request.form.get('password', '')

    user = authenticate_ldap(username, password)

    if not user:
        return render_template_string(
            LOGIN_TEMPLATE,
            error='Credenziali non valide o accesso non autorizzato.'
        ), 401

    session.clear()
    session['username'] = user['username']
    session['display_name'] = user['display_name']
    session['email'] = user['email']
    session['member_of'] = user['member_of']
    session['role'] = 'user'

    return redirect(url_for('home'))


@app.get('/')
def home():
    if 'username' not in session:
        return redirect(url_for('login'))

    # Dashboard di soli collegamenti: niente query al vecchio inventario.
    return render_template_string(
        DASHBOARD_TEMPLATE,
        services=SERVICES,
        display_name=session.get('display_name', session['username']),
        role=session.get('role', 'user')
    )

@app.get('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))
