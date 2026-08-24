#Tesztkörnyezet telepítése
Telepíts a hostra docker-t

#Tesztkonténer indítása
Példányosíts 3 wildfly konténert, a nevük wildfly_1 wildfly_2 wildfly_3

#filetípusok
Az összes ismert tanúsítványt és azok láncait kell kezelni
.cer .crt .pem .der .key 

#script létrehozása a hoston, nem a docker konténerben

A scriptnek linuxon kell futni, bash shellben, openssl segítségével, docker parancsokból
használhatod a cp-t a start-ot és a stop-ot, és a restartot.
Az eredeti konténernek meg kell maradnia!

Hozz létre egy listát a futó konténerekből, a listábol a felhasználó kiválaszt egy konténert.
A lista elemei mellett kell egy utolsó módosítás dátuma, év hó nap óra perc mp formátumban illetve a módosítás
sikeressége, OK / HIBA ezt majd a naplóból nyered ki.

A kiválasztott konténerből másold ki a java cacert állományt, egy automatikusan létrehozott könyvtárba Backup_$konténernév$_[éhónapnap_____óra:perc:máspderc] a könyvtárnév és azon belül a kulcstárat cacert_$konténernév$_backup néven. Másold ide megint $konténernév$_cacert néven, ezen fogsz dolgozni.

Megnyitod  a $konténernév$_cacert állományt, jelszót kérsz, alapesetben ez changeit ilyenkor csak egy enter kell.
Menj végig a certimport könyvtár elemein, itt találhatóak az importálandó tanúsítványok. 
A tanúsítványok lehetnek sima vagy tanúsítványláncok is, ilyenkor a lánc összes elemén végig kell menni.

Ellenőrízd, hogy már benne van-e az importálandó cert a tanúsítványtárban, amennyiben igen, akkor kérdezd meg felülírhatod-e, ellenőrzésnek írd ki a jelenlegi certimport
adatait, és az importálandó adatait. y igen , n nem, alapértelmezett a y, sima enter bevitelre is ezt hajtja végre.

Amikor minden elemen végigmentél a certimport könyvtárban, másold vissza a cacert állományt a wildfly konténeren belül
a megfelelő helyre, és docker restart al indítsd újra.

#Naplózás
A sikeres és sikertelen műveletekről napló állományt kell készíteni. Ez tartalmazza a dátum/idő illetve a módosításra került
konténer nevét és az importált tanúsítványokat, illetve hogy a feladat sikeres volt vagy nem. Egy naplófilet használhatsz
ebbe írod be incrementálisan az elvégzett műveleteket. Az allomány neve naplo.txt felbontása sima txt állomány.

#Leírás
githuban megfelelően gyárts egy README.md -t
Végezz teszteket a 3 konténerrel, a teszt tanúsítványokat is megkaptad, lehet pem vagy cer is.
