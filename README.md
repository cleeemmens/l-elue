# L'Élue

Appli web pour noter les candidates, faire ses pronos et jouer entre copines le soir de l'élection.

- `index.html` : l'appli (page unique, hébergée sur Netlify)
- `schema.sql` : la base de données Supabase (à lancer une fois dans le SQL Editor)

Page admin : `/#admin`

## Mise à jour
Après toute modification de `index.html`, lancer `python3 make-admin.py` pour régénérer `admin/index.html`.

## Tenir beaucoup de monde gratuitement (mise à jour n°5)
- Plus de connexion Supabase : chaque téléphone garde une clé secrète (`lelue-tok`), la base n'en stocke que l'empreinte.
- L'état de la soirée est publié par la page admin dans `state.json` (via une clé GitHub gardée sur le téléphone admin). Cloudflare Pages le sert gratuitement à tout le monde ; s'il est absent, l'appli lit la base (`public_state`).
- Le classement de la France est calculé par paquets à la clôture de chaque manche (`admin_fr_step` / `admin_fr_finish`).
- Après chaque modification de `index.html`, relancer `python3 make-admin.py`.
