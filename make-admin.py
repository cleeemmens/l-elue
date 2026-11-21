# Génère admin/index.html à partir de index.html (à relancer après chaque modification de index.html)
s=open('index.html',encoding='utf-8').read()
r=[('<title>L\'Élue · Note, pronostique, compare</title>','<title>L\'Élue · Admin</title>'),
   ('<meta name="apple-mobile-web-app-title" content="L\'Élue">','<meta name="apple-mobile-web-app-title" content="Admin">'),
   ('<link rel="icon" type="image/png" href="/icons/favicon-48.png">','<link rel="icon" type="image/png" href="/icons/admin-favicon-48.png">'),
   ('<link rel="apple-touch-icon" href="/icons/icon-180.png">','<link rel="apple-touch-icon" href="/icons/admin-180.png">'),
   ('<link rel="manifest" href="/manifest.webmanifest">','<link rel="manifest" href="/admin/manifest.webmanifest">'),
   ('<script>\n/* ===================== CONFIG','<script>window.FORCE_ADMIN=true;</script>\n<script>\n/* ===================== CONFIG')]
for a,b in r:
    assert a in s, a
    s=s.replace(a,b,1)
open('admin/index.html','w',encoding='utf-8').write(s)
print('admin/index.html généré')
