# Recette de validation — F010 OpenTelemetry Instrumentation

## Prerequis

### Infrastructure

```bash
# Lancer Jaeger all-in-one (OTLP HTTP + UI traces)
docker run -d --name jaeger \
  -p 4318:4318 \
  -p 16686:16686 \
  jaegertracing/all-in-one:latest
```

Verifier : http://localhost:16686 affiche l'UI Jaeger.

### Build ztick

```bash
make build
```

### Configuration

Utiliser `example/config-telemetry.toml` :

```toml
[log]
level = "info"

[controller]
listen = "127.0.0.1:5678"

[database]
fsync_on_persist = false
framerate = 512
logfile_path = "ztick.log"

[telemetry]
enabled = true
endpoint = "http://localhost:4318"
service_name = "ztick"
flush_interval_ms = 5000
```

---

## US3 — Configuration telemetrie (P1)

### R01 : Telemetrie desactivee par defaut

**Etapes :**
1. Demarrer ztick sans section `[telemetry]` :
   ```bash
   echo '[log]\nlevel = "info"\n[controller]\nlisten = "127.0.0.1:5678"' > /tmp/ztick-notel.toml
   zig build run -- -c /tmp/ztick-notel.toml
   ```
2. Observer la sortie stderr

**Attendu :** Ztick demarre normalement, aucune mention de telemetrie dans les logs, aucune requete HTTP vers le port 4318.

**Verification :**
```bash
# Dans un autre terminal, avant de demarrer ztick :
ss -tlnp | grep 4318
# Rien ne doit apparaitre cote ztick
```

---

### R02 : Cle inconnue rejetee au demarrage

**Etapes :**
1. Creer un fichier config avec une cle invalide :
   ```bash
   cat > /tmp/ztick-badkey.toml << 'EOF'
   [telemetry]
   enabled = true
   endpoint = "http://localhost:4318"
   unknown_key = true
   EOF
   ```
2. Demarrer ztick :
   ```bash
   zig build run -- -c /tmp/ztick-badkey.toml
   ```

**Attendu :** Ztick refuse de demarrer avec une erreur `ConfigError` identifiant `unknown_key`.

---

### R03 : Endpoint absent rejete

**Etapes :**
1. Creer un fichier config avec `enabled = true` mais sans endpoint :
   ```bash
   cat > /tmp/ztick-noep.toml << 'EOF'
   [telemetry]
   enabled = true
   service_name = "ztick"
   EOF
   ```
2. Demarrer ztick :
   ```bash
   zig build run -- -c /tmp/ztick-noep.toml
   ```

**Attendu :** Ztick refuse de demarrer avec une erreur de configuration.

---

### R04 : Telemetrie active avec endpoint valide

**Etapes :**
1. Demarrer ztick :
   ```bash
   zig build run -- -c example/config-telemetry.toml
   ```
2. Observer les logs

**Attendu :** Ztick demarre, les logs affichent le niveau, l'adresse d'ecoute. Pas d'erreur liee a la telemetrie.

---

## US1 — Export metriques (P1)

### R05 : Compteur jobs_scheduled incremente sur SET

**Prerequis :** R04 en cours (ztick tourne avec telemetrie).

**Etapes :**
1. Envoyer 3 commandes SET :
   ```bash
   echo "req.1 SET job.alpha 1000000000" | socat - TCP:127.0.0.1:5678
   echo "req.2 SET job.beta 2000000000" | socat - TCP:127.0.0.1:5678
   echo "req.3 SET job.gamma 3000000000" | socat - TCP:127.0.0.1:5678
   ```
2. Verifier les reponses : chaque commande doit retourner `req.X OK`
3. Attendre 5 secondes (flush_interval_ms)
4. Consulter les metriques dans Jaeger ou via l'API OTLP

**Attendu :** Le compteur `jobs_scheduled` vaut 3.

**Verification alternative (via logs ztick) :**
Les logs stderr de ztick en mode `debug` doivent montrer les instructions recues.

---

### R06 : Compteur jobs_removed incremente sur REMOVE

**Etapes :**
1. Supprimer un job :
   ```bash
   echo "req.4 REMOVE job.beta" | socat - TCP:127.0.0.1:5678
   ```
2. Verifier la reponse : `req.4 OK`

**Attendu :** Le compteur `jobs_removed` vaut 1.

---

### R07 : Gauge rules_active incremente/decremente

**Etapes :**
1. Creer 2 regles :
   ```bash
   echo 'req.5 RULE SET rule.echo echo. shell /bin/echo' | socat - TCP:127.0.0.1:5678
   echo 'req.6 RULE SET rule.true true. shell /bin/true' | socat - TCP:127.0.0.1:5678
   ```
2. Supprimer 1 regle :
   ```bash
   echo "req.7 REMOVERULE rule.true" | socat - TCP:127.0.0.1:5678
   ```

**Attendu :** Le gauge `rules_active` vaut 1 (2 ajouts - 1 suppression).

---

### R08 : Gauge connections_active reflete les connexions TCP

**Etapes :**
1. Ouvrir une connexion TCP persistante :
   ```bash
   socat - TCP:127.0.0.1:5678 &
   SOCAT_PID=$!
   ```
2. Attendre 1 seconde, le gauge `connections_active` doit etre >= 1
3. Fermer la connexion :
   ```bash
   kill $SOCAT_PID
   ```
4. Attendre 1 seconde, le gauge doit revenir a 0

**Attendu :** Le gauge suit les connexions/deconnexions en temps reel.

---

### R09 : Histogramme execution_duration_ms sur execution reussie

**Etapes :**
1. Creer une regle qui match un pattern :
   ```bash
   echo 'req.10 RULE SET rule.hist hist. shell /bin/true' | socat - TCP:127.0.0.1:5678
   ```
2. Creer un job avec un timestamp passe (execution immediate) :
   ```bash
   echo "req.11 SET hist.job.1 1" | socat - TCP:127.0.0.1:5678
   ```
3. Attendre 2 secondes (le scheduler doit executer le job)
4. Attendre le flush (5s)

**Attendu :** L'histogramme `execution_duration_ms` a au moins 1 enregistrement. Le compteur `jobs_executed` vaut 1.

---

### R10 : Telemetrie zero-overhead quand desactivee

**Etapes :**
1. Demarrer ztick sans telemetrie (R01)
2. Envoyer des commandes SET, REMOVE, RULE SET
3. Observer les performances et l'utilisation memoire

**Attendu :** Aucune requete HTTP, aucun thread supplementaire, aucune allocation liee a la telemetrie. Comportement identique a une version sans code de telemetrie.

---

## US2 — Export traces (P2)

### R11 : Span de requete sur SET

**Prerequis :** R04 en cours (ztick tourne avec telemetrie + Jaeger).

**Etapes :**
1. Envoyer une commande SET :
   ```bash
   echo "req.20 SET trace.job.1 1000000000" | socat - TCP:127.0.0.1:5678
   ```
2. Ouvrir Jaeger : http://localhost:16686
3. Selectionner le service `ztick`
4. Chercher les traces recentes

**Attendu :** Une trace avec un span `ztick.request` est visible dans Jaeger.

---

### R12 : Span de requete couvre l'operation complete

**Prerequis :** R11 execute.

**Etapes :**
1. Consulter le detail du span `ztick.request` dans Jaeger

**Attendu :** Le span a une duree > 0μs, couvrant le traitement complet de la requete (parse → persistence → response). Le service affiche "ztick" (pas "missing-service-name").

---

## US4 — Export logs (P3)

### R13 : Logs warn+ exportes via OTLP

**Etapes :**
1. Demarrer ztick avec telemetrie activee
2. Provoquer un warning (par exemple, charger un logfile corrompu ou envoyer une commande invalide)
3. Observer Jaeger ou le collecteur OTLP

**Attendu :** Les logs de niveau warn et superieur apparaissent dans le collecteur OTLP sous `/v1/logs`. Les logs sont aussi affiches sur stderr (dual output via `also_log_to_stderr = true`).

---

## Edge Cases

### R14 : Collecteur OTLP inaccessible

**Etapes :**
1. Arreter le container Jaeger :
   ```bash
   docker stop jaeger
   ```
2. Demarrer ztick avec telemetrie pointant vers `localhost:4318`
3. Envoyer des commandes SET, REMOVE

**Attendu :** Ztick fonctionne normalement. Les commandes retournent OK. Les exports OTLP echouent silencieusement (timeout 2s, 0 retries). Le scheduler tick loop n'est pas bloque.

---

### R15 : Reprise apres retour du collecteur

**Etapes :**
1. Suite de R14 — relancer le collecteur :
   ```bash
   docker start jaeger
   ```
2. Envoyer de nouvelles commandes
3. Attendre le flush (5s)

**Attendu :** Les nouvelles metriques et traces sont exportees normalement. Les donnees perdues pendant l'indisponibilite ne sont pas recuperees (expected — pas de buffer persistant).

---

## Nettoyage

```bash
docker stop jaeger && docker rm jaeger
rm -f ztick.log ztick.log.compressed ztick.log.to_compress
rm -f /tmp/ztick-notel.toml /tmp/ztick-badkey.toml /tmp/ztick-noep.toml
```

---

## Resume des criteres

| # | User Story | Description | Priorite |
|---|-----------|-------------|----------|
| R01 | US3 | Telemetrie desactivee par defaut | P1 |
| R02 | US3 | Cle inconnue rejetee | P1 |
| R03 | US3 | Endpoint absent rejete | P1 |
| R04 | US3 | Telemetrie active avec endpoint valide | P1 |
| R05 | US1 | Compteur jobs_scheduled | P1 |
| R06 | US1 | Compteur jobs_removed | P1 |
| R07 | US1 | Gauge rules_active | P1 |
| R08 | US1 | Gauge connections_active | P1 |
| R09 | US1 | Histogramme execution_duration_ms | P1 |
| R10 | US1 | Zero-overhead quand desactive | P1 |
| R11 | US2 | Span de requete | P2 |
| R12 | US2 | Span duree > 0 et service name correct | P2 |
| R13 | US4 | Logs warn+ exportes | P3 |
| R14 | Edge | Collecteur inaccessible | P1 |
| R15 | Edge | Reprise apres retour collecteur | P1 |

---

*Recette generee pour F010 v0.1.1 — zig-o11y/opentelemetry-sdk*
