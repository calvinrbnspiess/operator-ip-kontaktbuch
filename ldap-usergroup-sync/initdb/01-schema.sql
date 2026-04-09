CREATE TABLE public.persontypes (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    short text NOT NULL
);

CREATE TABLE public.people (
    id bigserial PRIMARY KEY,
    "persontypeId" bigint REFERENCES public.persontypes(id),
    sex bigint NOT NULL,
    "lastName" text NOT NULL,
    "firstName" text,
    "personNumber" bigint,
    active boolean NOT NULL DEFAULT true,
    "exportFlag" boolean DEFAULT false
);

CREATE TABLE public.departments (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    short text NOT NULL,
    active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.persondepartments (
    id bigserial PRIMARY KEY,
    "personId" bigint NOT NULL REFERENCES public.people(id),
    "departmentId" bigint NOT NULL REFERENCES public.departments(id),
    "memberFrom" timestamp without time zone,
    "memberUntil" timestamp without time zone
);

CREATE TABLE public.functions (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    description text,
    active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.personfunctions (
    id bigserial PRIMARY KEY,
    "personId" bigint NOT NULL REFERENCES public.people(id),
    "funcId" bigint NOT NULL REFERENCES public.functions(id),
    "validFrom" timestamp without time zone NOT NULL,
    "validUntil" timestamp without time zone
);
