# v2
# Dockercert WildFly

Hostoldali bash script, ami futó WildFly Docker-konténerek Java `cacerts` truststore-jába importál tanúsítványokat. A munka a hoston történik: a kulcstárat `docker cp` másolja ki, openssl és keytool dolgozik rajta, majd a módosított fájl visszakerül a **ugyanabba** a konténerbe (`docker restart`). Az eredeti konténer nem törlődik és nem cserélődik le.

## Követelmények

- Docker (a konténerek futtatásához)
- OpenSSL
- bash
- `certimport/` könyvtár a beimportálandó fájlokkal

A Java `keytool` a célkonténer image-éből fut (`--user` = a hívó UID, SELinux `:z` a bind-mounton), a hostra nem kell JDK.

## Tesztkonténerek

```bash
docker run -d --name wildfly_1 -p 8081:8080 quay.io/wildfly/wildfly:36.0.1.Final-jdk17
docker run -d --name wildfly_2 -p 8082:8080 quay.io/wildfly/wildfly:36.0.1.Final-jdk17
docker run -d --name wildfly_3 -p 8083:8080 quay.io/wildfly/wildfly:36.0.1.Final-jdk17
```

A `latest` WildFly image x86-64-v3 CPU-t igényelhet; a fenti JDK 17-es tag régebbi gépeken is elindul.

## Használat

```bash
./import_cacerts.sh
./import_cacerts.sh wildfly_1
# vagy a szerveren használt név:
./certimport.sh
```

1. A script listázza a futó konténereket. Minden sornál megjelenik az **utolsó módosítás** dátuma (`év.hó.nap óra:perc:mp`) és az eredmény (`OK` / `HIBA`) a `naplo.txt` alapján.
2. A kiválasztott konténer `cacerts` fájlja a `Backup_<konténer>_<ééééhhnn_____óra:perc:mp>/` mappába kerül:
   - `cacert_<konténer>_backup` — érintetlen másolat
   - `<konténer>_cacert` — munkapéldány
3. Kulcstár jelszó: Enter = `changeit`.
4. A `certimport/` minden ismert tanúsítványán végigmegy. Ha a cert már bent van, kiírja a bent lévő és az importálandó adatait; `Y/n`, Enter = felülírás.
5. Visszamásolja a kulcstárat a **feloldott** útvonalra (`readlink -f`, pl. `/etc/pki/ca-trust/extracted/java/cacerts`), szimbolikus linket nem tör. Az eredeti UID/GID/mód (`chown`/`chmod`) megmarad, majd `docker restart`.

## Támogatott fájltípusok

| Kiterjesztés | Megjegyzés |
| --- | --- |
| `.pem` `.crt` `.cer` | PEM vagy DER X.509, lánc is (több `BEGIN CERTIFICATE`) |
| `.der` | bináris X.509 |
| `.key` | ha van benne tanúsítvány, azt importálja; tiszta privát kulcsot kihagyja (a `cacerts` truststore, nem keystore) |
| `.p7b` `.p7c` | PKCS#7 lánc |

## Napló

A műveletek a `naplo.txt` fájlba íródnak, hozzáfűzve:

```
2026.08.24 15:14:31 | wildfly_1 | OK | importált: file.cer [1/1]
2026.08.24 15:20:01 | wildfly_2 | HIBA | a kulcstár nem nyitható meg (hibás jelszó?)
```

## Könyvtárak

- `certimport/` — bemeneti tanúsítványok
- `Backup_*` — futtatásonkénti munkamásolat (gitignore)
- `naplo.txt` — üzemeltetési napló (gitignore)


