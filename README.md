Start docker compose with project name "operator-ip-kontaktbuch":
```docker compose -p operator-ip-kontaktbuch up -d```

Import a SQL file into PostgreSQL:
```docker compose -p operator-ip-kontaktbuch exec -T postgres psql -U postgres -d db < Datenabzug/Datenbank/backup.sql```

Or if the containers are already running:
```docker exec -i postgres psql -U postgres -d db < path/to/your/file.sql```

table: addresstypes
7 -> feuerwehr
8 -> hersteller
9 -> kats


Anrede,Vorname,Weitere Vornamen,Nachname,Suffix,Firma,Abteilung,Position,Straße geschäftlich,Straße geschäftlich 2,Straße geschäftlich 3,Ort geschäftlich,Region geschäftlich,Postleitzahl geschäftlich,Land/Region geschäftlich,Straße privat,Straße privat 2,Straße privat 3,Ort privat,Bundesland/Kanton privat,Postleitzahl privat,Land/Region privat,Weitere Straße,Weitere Straße 2,Weitere Straße 3,Weiterer Ort,Weiteres/r Bundesland/Kanton,Weitere Postleitzahl,Weiteres/e Land/Region,Telefon Assistent,Fax geschäftlich,Telefon geschäftlich,Telefon geschäftlich 2,Rückmeldung,Autotelefon,Telefon Firma,Fax privat,Telefon (privat),Telefon (privat 2),ISDN,Mobiltelefon,Weiteres Fax,Weiteres Telefon,Pager,Haupttelefon,Mobiltelefon 2,Telefon für Hörbehinderte,Telex,Abrechnungsinformation,Assistent(in),Benutzer 1,Benutzer 2,Benutzer 3,Benutzer 4,Beruf,Büro,E-Mail-Adresse,E-Mail-Typ,E-Mail: Angezeigter Name,E-Mail 2: Adresse,E-Mail 2: Typ,E-Mail 2: Angezeigter Name,E-Mail 3: Adresse,E-Mail 3: Typ,E-Mail 3: Angezeigter Name,Empfohlen von,Geburtstag,Geschlecht,Hobby,Initialen,Internet Frei/Gebucht,Jahrestag,Kategorien,Kinder,Konto,Name des/r Vorgesetzten,Notizen,Organisationsnr.,Ort,Partner,Postfach geschäftlich,Postfach privat,Priorität,Privat,Reisekilometer,Sozialversicherungsnr.,Sprache,Stichwörter,Vertraulichkeit,Verzeichnisserver,Webseite,Weiteres Postfach,Spalte1,Spalte2

TecBosWeb Datenbank läuft auf docker mit einer PostgreSQL 

FEZ neu braucht die Telefondaten von Personen und Firmen als kommagetrennte CSV


Einfach ausgedrückt abfrage an Datenbank, Gib alle IDs inkl Name und Vorname wo im Feld Export Fez eine 1 steht
Suche unter Erreichbarkeit die Person anhand der ID, suche dann nach Art "mobil" und schreibe wenn gefunden in die Spalte mobil der csv

[20:05, 23.10.2025] Nicolas Glatz: da bin ich ehrlich, mag ich evt. auch keinen automatisimus
[20:05, 23.10.2025] Nicolas Glatz: nicht dass Datei auf einmal fehlerhaft und dann Adressbuch leer
[20:54, 23.10.2025] Nicolas Glatz: geht doch nichts über Putty wenn man mir die Funktion (notwendige Treiber) in DBEaver nicht freigbt
[20:54, 23.10.2025] Nicolas Glatz: 800MB Datenbank liegen in der Cloud
[21:02, 23.10.2025] Nicolas Glatz: alle Einträge sind ID's
, l
also es gibt unter people dich mit einer id

dann gibt es reachabilitytypes mit einer ID für z.B. "Telefon mobil"
und dann gibt es "reachabilities" wenn man da nun deine ID und die erreichbarkeitsid eingibt, bekommt man deine Handynummer
[21:04, 23.10.2025] Nicolas Glatz: und Firmen sind unter "Adresses" und die Ansprechparnter der Firmen unter "contacts"
[21:04, 23.10.2025] Nicolas Glatz: bei der Person gibt es ein "Export Flag"
bei der Firma und bei den Kontakten ebenfalls.

[21:02, 23.10.2025] Nicolas Glatz: alle Einträge sind ID's

also es gibt unter people dich mit einer id

dann gibt es reachabilitytypes mit einer ID für z.B. "Telefon mobil"
und dann gibt es "reachabilities" wenn man da nun deine ID und die erreichbarkeitsid eingibt, bekommt man deine Handynummer
[21:04, 23.10.2025] Nicolas Glatz: und Firmen sind unter "Adresses" und die Ansprechparnter der Firmen unter "contacts"
[21:04, 23.10.2025] Nicolas Glatz: bei der Person gibt es ein "Export Flag"
bei der Firma und bei den Kontakten ebenfalls.

Alle Kontakte abrufen:
SELECT id, "firstName", "lastName", "phone1", "phone2", "phone3", "fax", "mobile1", "mobile2", "functionName", "addressId" FROM contacts WHERE "exportFlag" IS TRUE
ORDER BY id ASC

Alle Firmen abrufen:

SELECT id, "name1", "short", "phone", "fax" FROM public.addresses WHERE "exportFlag" IS TRUE
ORDER BY id ASC 

Alle Personen: 

SELECT "id", "firstName", "lastName", "persontypeId", "personNumber" FROM public.people
WHERE "exportFlag" IS TRUE ORDER BY id ASC 

Erreichbarkeiten einer Person abrufen:

SELECT "content" FROM public.reachabilities WHERE "personId" = 202 AND "reachabilitytypeId" = 2
ORDER BY id ASC 

Firmen -> ADRESSES
Ansprechpartner -> CONTACTS
reachabilities, reachabilitytypes



CSV braucht:
- Haupttelefon
- Mobiltelefon
- Telefon Firma
- Telefon geschäftlich
- Firma
oder
- Vorname, Nachname





Schritt 1:
- Rufe alle Firmen ab
- Rufe alle Ansprechpartner der Firmen ab
- Rufe alle Personen ab

Testing: docker compose -f docker-compose.yaml -f ldap-sync/ldap-usergroup-sync/docker-compose.yaml run --rm ldap-sync bash test.sh