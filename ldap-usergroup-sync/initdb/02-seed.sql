-- Person types (mirror production: name, short pairs used as LDAP CN prefix).
INSERT INTO public.persontypes (id, name, short) VALUES
    (1, 'eigenes Personal',            'P'),
    (2, 'Mitarbeiter Stadtverwaltung', 'SV'),
    (3, 'KatS-Stab',                   'K'),
    (4, 'externe Kräfte',              'E'),
    (5, 'Testperson',                  'TEST');
SELECT setval('persontypes_id_seq', 100);

-- Departments (IDs must match seed.sh references)
INSERT INTO public.departments (id, name, short, active) VALUES
    ( 4, 'Landau-Dammheim', 'LD-DA', true),
    (10, 'Landau-Stadt',    'LD-ST', true),
    (18, 'Gefahrstoffzug',  'GSZ',   true);
SELECT setval('departments_id_seq', 100);

-- Functions (IDs must match seed.sh references)
INSERT INTO public.functions (id, name, description, active) VALUES
    ( 1, 'Wehrführer',                'Wehrführer',               true),
    ( 3, 'Atemschutzgeräteträger/in',  'Atemschutzgeräteträger',        true),
    (40, 'Korbfahrer',                 'Drehleiter-Korbfahrer',         true);
SELECT setval('functions_id_seq', 100);
