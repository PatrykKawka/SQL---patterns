# ARRAY, STRUCT, UNNEST w BigQuery — od podstaw do zaawansowanych receptur

> **Uwaga metodologiczna:** ten dokument nie został wykonany na żywym BigQuery w tej sesji (brak dostępu w tym środowisku) — inaczej niż notatniki Python w tym repo, które testowałem end-to-end. Składnia poniżej opiera się na stabilnej, dobrze udokumentowanej funkcjonalności BigQuery Standard SQL. Zanim potraktujesz coś jako pewnik, zweryfikuj kluczowe zapytania na `bigquery-public-data` — szczególnie te oznaczone jako "receptura".

## Dlaczego to w ogóle inny model niż T-SQL

W T-SQL projektujesz pod **pierwszą postać normalną**: jedna wartość w komórce, relacje jeden-do-wielu wymagają osobnej tabeli połączonej kluczem obcym. Zamówienie i jego pozycje to zawsze dwie tabele (`Orders`, `OrderItems`) połączone `JOIN`-em.

BigQuery pozwala złamać tę zasadę **celowo**: kolumna może być:
- **`REPEATED`** — tablica wartości tego samego typu (`ARRAY`),
- **`RECORD`** — zagnieżdżona struktura pól różnych typów (`STRUCT`),
- **`REPEATED RECORD`** — tablica struktur, czyli dokładnie to, co w T-SQL byłoby osobną tabelą `OrderItems` — tu zamiast tego siedzi jako jedna kolumna w tabeli `Orders`.

**Dlaczego to ma sens akurat w BigQuery, a nie w T-SQL:** silnik kolumnowy BigQuery jest zoptymalizowany pod czytanie całych kolumn naraz, a `JOIN` na danych rozproszonych między węzłami jest kosztowny. Trzymanie relacji 1:N w jednym wierszu (denormalizacja przez zagnieżdżenie) eliminuje `JOIN` tam, gdzie w T-SQL byłby nieunikniony. To nie jest "gorszy projekt bazy" — to inny kompromis, świadomie zaprojektowany pod inny silnik wykonawczy.

---

## Część 1 — Podstawy `ARRAY`

### 1.1 Czym jest `ARRAY`

Typ kolumny reprezentujący uporządkowaną listę wartości **tego samego typu**. Odpowiednika w T-SQL po prostu nie ma jako typu kolumny (najbliżej jest `STRING_SPLIT`, ale to funkcja, nie typ danych do przechowywania).

### 1.2 Tworzenie tablic — literały

```sql
SELECT [1, 2, 3] AS numbers;                    -- typ wywnioskowany automatycznie
SELECT ARRAY<INT64>[1, 2, 3] AS numbers;        -- typ jawny
SELECT ARRAY[1, 2, 3] AS numbers;               -- forma pośrednia
```

### 1.3 Generowanie tablic: `GENERATE_ARRAY`, `GENERATE_DATE_ARRAY`

Przydatne do budowania sekwencji bez tabeli pomocniczej (`tally table`, którą w T-SQL trzeba by sobie stworzyć ręcznie albo przez rekurencyjny CTE).

```sql
SELECT GENERATE_ARRAY(1, 10, 2) AS odd_numbers;
-- [1, 3, 5, 7, 9]

SELECT GENERATE_DATE_ARRAY('2026-01-01', '2026-01-05') AS days;
-- [2026-01-01, 2026-01-02, 2026-01-03, 2026-01-04, 2026-01-05]
```

**Recepta — kalendarz dat bez tabeli pomocniczej** (w T-SQL wymagałoby to rekurencyjnego CTE albo dedykowanej tabeli `Calendar`):

```sql
SELECT day
FROM UNNEST(GENERATE_DATE_ARRAY('2026-01-01', '2026-12-31')) AS day;
```

### 1.4 Dostęp do elementów: `OFFSET` vs `ORDINAL`

**To jedna z najczęstszych pomyłek** — BigQuery ma DWA sposoby indeksowania tablicy, licząc od różnych punktów:

```sql
SELECT
  my_array[OFFSET(0)]  AS first_element,   -- OFFSET liczy od 0 (jak Python/pandas)
  my_array[ORDINAL(1)] AS also_first       -- ORDINAL liczy od 1 (jak większość ludzi by zgadła)
FROM (SELECT [10, 20, 30] AS my_array);
```

Oba zwrócą `10` dla pierwszego elementu — różnica ujawnia się dopiero przy indeksie > 0. `my_array[OFFSET(1)]` da `20`, `my_array[ORDINAL(1)]` da `10`. Mieszanie tych dwóch w jednym projekcie to prosta droga do błędu off-by-one.

### 1.5 `ARRAY_LENGTH`

```sql
SELECT ARRAY_LENGTH([10, 20, 30]) AS n;  -- 3
```

### 1.6 Tekst ↔ tablica: `ARRAY_TO_STRING`, `SPLIT`

Bezpośrednie odpowiedniki T-SQL `STRING_AGG` (w drugą stronę) i `STRING_SPLIT`:

```sql
SELECT ARRAY_TO_STRING(['a', 'b', 'c'], ', ') AS joined;  -- 'a, b, c'
SELECT SPLIT('a,b,c', ',') AS parts;                       -- ['a', 'b', 'c']
```

### 1.7 `ARRAY_AGG` — agregacja wielu wierszy do JEDNEJ tablicy

To jest funkcjonalny odpowiednik T-SQL `STRING_AGG`, ale zwraca **prawdziwą tablicę** (typowaną, z zachowanymi typami elementów), nie sklejony tekst. Kluczowa funkcja — wraca w niemal każdej recepturze w tym dokumencie.

```sql
SELECT
  customer_id,
  ARRAY_AGG(product_name) AS products_bought
FROM orders
GROUP BY customer_id;
```

---

## Część 2 — Podstawy `STRUCT`

### 2.1 Czym jest `STRUCT`

Zagnieżdżony "rekord" — grupa pól o RÓŻNYCH typach pod jedną kolumną, jak pojedynczy wiersz zagnieżdżony wewnątrz innej kolumny. W T-SQL nie masz na to bezpośredniego odpowiednika — najbliżej koncepcyjnie jest kolumna typu `XML`/`JSON`, ale bez natywnego typowania pól.

### 2.2 Tworzenie `STRUCT`

```sql
SELECT STRUCT(1 AS id, 'Anna' AS name) AS person;
-- albo krócej, bez nazwanych pól:
SELECT (1, 'Anna') AS person;
```

### 2.3 Dostęp do pól przez kropkę

```sql
SELECT person.id, person.name
FROM (SELECT STRUCT(1 AS id, 'Anna' AS name) AS person);
```

### 2.4 Zagnieżdżanie `STRUCT` w `STRUCT`

```sql
SELECT STRUCT(
  1 AS id,
  STRUCT('Warszawa' AS city, '00-001' AS postal_code) AS address
) AS customer;

-- dostęp: customer.address.city
```

### 2.5 `STRUCT` vs `ARRAY` — kluczowa różnica pojęciowa

| | `STRUCT` | `ARRAY` |
|---|---|---|
| Zawartość | Różne typy, stałe nazwy pól | Ten sam typ, dowolna liczba elementów |
| Analogia | Jeden wiersz zagnieżdżony w kolumnie | Lista wartości w kolumnie |
| Dostęp | `.nazwa_pola` | `[OFFSET(n)]` / `UNNEST()` |

---

## Część 3 — `ARRAY<STRUCT<...>>`: najważniejszy, najczęstszy wzorzec

Połączenie obu: kolumna zawierająca **tablicę struktur**. To jest dokładnie ten przypadek, który w T-SQL wymagałby osobnej tabeli połączonej `FOREIGN KEY`.

```sql
-- Jeden wiersz = jedno zamówienie, z zagnieżdżoną listą pozycji
SELECT
  1001 AS order_id,
  'Anna Kowalska' AS customer_name,
  [
    STRUCT('Router' AS product, 2 AS qty, 150.00 AS unit_price),
    STRUCT('Kabel HDMI' AS product, 1 AS qty, 25.00 AS unit_price)
  ] AS line_items;
```

**Analogia do T-SQL:** to zastępuje parę tabel `Orders` + `OrderItems` połączonych przez `order_id`. Tu `line_items` to cała zawartość tego, co w T-SQL siedziałoby w osobnej tabeli — ale przechowywana w jednym wierszu `Orders`.

---

## Część 4 — `UNNEST`: rozpakowanie tablicy z powrotem do wierszy

### 4.1 Podstawowa składnia

```sql
SELECT x
FROM UNNEST([10, 20, 30]) AS x;
-- 3 wiersze: 10, 20, 30
```

### 4.2 `UNNEST` połączony z tabelą — spłaszczenie zagnieżdżonych danych

To jest bezpośredni odpowiednik `DataFrame.explode()` z notatki o reshapingu w tym repo — z zagnieżdżonego formatu "szerokiego" (jeden wiersz z tablicą) do formatu "długiego" (jeden wiersz na element tablicy).

```sql
SELECT
  order_id,
  customer_name,
  item.product,
  item.qty,
  item.unit_price
FROM orders
CROSS JOIN UNNEST(line_items) AS item;
```

Każda pozycja zamówienia staje się osobnym wierszem, z `order_id`/`customer_name` powielonym — dokładnie jak `explode()` w pandas.

### 4.3 `WITH OFFSET` — zachowanie pozycji elementu

Odpowiednik `enumerate()` — przydatne, gdy kolejność w tablicy niesie znaczenie (np. "pierwsza pozycja zamówienia").

```sql
SELECT
  order_id,
  item.product,
  pos AS item_position
FROM orders
CROSS JOIN UNNEST(line_items) AS item WITH OFFSET AS pos;
```

### 4.4 `LEFT JOIN UNNEST` — zachowanie wierszy z PUSTĄ tablicą

**To jest realna pułapka (patrz też Część 6):** domyślny `CROSS JOIN UNNEST` GUBI wiersze, których tablica jest pusta lub `NULL` — zamówienie bez pozycji po prostu znika z wyniku. `LEFT JOIN UNNEST` zachowuje taki wiersz, z polami z `UNNEST` jako `NULL`.

```sql
SELECT
  order_id,
  customer_name,
  item.product   -- NULL, jeśli zamówienie nie miało żadnych pozycji
FROM orders
LEFT JOIN UNNEST(line_items) AS item;
```

---

## Część 5 — Gotowe receptury

### Receptura 1 — Odwrotność `UNNEST`: budowanie zagnieżdżonej struktury z płaskich danych

Klasyczny scenariusz migracji z T-SQL: masz płaską tabelę (jak `OrderItems` w T-SQL) i chcesz ją zagnieździć w `Orders`, żeby uniknąć `JOIN`-a przy każdym zapytaniu.

```sql
SELECT
  order_id,
  ANY_VALUE(customer_name) AS customer_name,  -- ta sama wartość w każdym wierszu grupy
  ARRAY_AGG(STRUCT(product, qty, unit_price)) AS line_items
FROM flat_order_items
GROUP BY order_id;
```

To jest dokładny odpowiednik `groupby(...).agg(list)` z notatki o grupowaniu w pandas — tylko wynikiem jest prawdziwa zagnieżdżona struktura typowana przez BigQuery, nie kolumna z obiektami Python.

### Receptura 2 — Filtrowanie WEWNĄTRZ tablicy, bez pełnego `UNNEST`

Gdy potrzebujesz tylko sprawdzić, czy tablica SPEŁNIA warunek (nie potrzebujesz spłaszczonych wierszy do dalszej analizy), podzapytanie z `UNNEST` w `WHERE` jest tańsze niż pełny `JOIN`:

```sql
-- Zamówienia zawierające przynajmniej jedną pozycję droższą niż 100
SELECT order_id, customer_name
FROM orders
WHERE EXISTS (
  SELECT 1 FROM UNNEST(line_items) AS item WHERE item.unit_price > 100
);
```

### Receptura 3 — Liczba elementów tablicy spełniających warunek

```sql
SELECT
  order_id,
  (SELECT COUNT(*) FROM UNNEST(line_items) AS item WHERE item.qty > 1) AS multi_unit_items
FROM orders;
```

### Receptura 4 — `ARRAY_AGG` z `ORDER BY`, `LIMIT`, `DISTINCT`

`ARRAY_AGG` przyjmuje własne `ORDER BY`/`LIMIT` NIEZALEŻNIE od reszty zapytania — przydatne np. do wzięcia trzech najdroższych pozycji per zamówienie.

```sql
SELECT
  order_id,
  ARRAY_AGG(DISTINCT product ORDER BY unit_price DESC LIMIT 3) AS top_3_products
FROM flat_order_items
GROUP BY order_id;
```

### Receptura 5 — "Najnowszy rekord na grupę" (deduplikacja) przez `ARRAY_AGG`

Klasyczny idiom BigQuery na zadanie, które w T-SQL rozwiązuje się przez `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...) = 1`:

```sql
SELECT
  customer_id,
  ARRAY_AGG(row ORDER BY updated_at DESC LIMIT 1)[OFFSET(0)].*
FROM customer_updates AS row
GROUP BY customer_id;
```

`ARRAY_AGG(... LIMIT 1)` daje tablicę z jednym elementem (najnowszym wierszem), `[OFFSET(0)]` go wyciąga, `.*` rozwija z powrotem pola struktury do zwykłych kolumn. Alternatywa dla `QUALIFY ROW_NUMBER() OVER (...) = 1`, jeśli wolisz styl funkcyjny nad okienkowy.

### Receptura 6 — Sprawdzenie schematu tabeli z polami zagnieżdżonymi

Zanim napiszesz `UNNEST` na nieznanej tabeli publicznej, sprawdź strukturę — pola `REPEATED`/`RECORD` są widoczne w `INFORMATION_SCHEMA` albo bezpośrednio w podglądzie schematu w konsoli:

```sql
SELECT column_name, data_type
FROM `bigquery-public-data.samples.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'nazwa_tabeli';
```

W wyniku pola zagnieżdżone mają typ zaczynający się od `STRUCT<...>` albo `ARRAY<STRUCT<...>>` — od razu widać, czy potrzebny będzie `UNNEST`.

---

## Część 6 — Pułapki

### Pułapka 1 — `CROSS JOIN UNNEST` domyślnie gubi wiersze z pustą/`NULL` tablicą

Opisane w 4.4. Jeśli liczba wierszy po `UNNEST` jest mniejsza niż się spodziewałeś, to pierwsze podejrzenie: sprawdź, czy któreś tablice są puste, i rozważ `LEFT JOIN UNNEST` zamiast domyślnego `CROSS JOIN UNNEST` (`UNNEST` w klauzuli `FROM` bez jawnego `JOIN` zachowuje się jak `CROSS JOIN`).

### Pułapka 2 — `OFFSET` vs `ORDINAL`: błąd o jeden element

Opisane w 1.4. Jeśli kod migrowany z innego projektu/dialektu nagle daje wyniki przesunięte o jeden element, sprawdź, czy nie doszło do pomieszania tych dwóch.

### Pułapka 3 — `SELECT *` na tabeli z głęboko zagnieżdżonymi polami bywa droższe niż wygląda

BigQuery liczy koszt zapytania na podstawie przeskanowanych KOLUMN, nie wierszy — ale kolumna `REPEATED RECORD` z wieloma polami wewnątrz to nadal "jedna kolumna" do rozliczenia, choć w praktyce niesie dane wielu logicznych kolumn naraz. `SELECT *` na takiej tabeli często skanuje więcej danych, niż intuicyjnie się wydaje. Selekcja tylko potrzebnych pól zagnieżdżonych (`item.product`, nie `item.*` albo `*`) obniża koszt.

### Pułapka 4 — `STRUCT` bez nazwanych pól utrudnia dalsze odwołania

`SELECT (1, 'Anna')` tworzy `STRUCT` z polami o automatycznych nazwach (`field1`, `field2` — dokładna konwencja zależy od kontekstu zapytania). Jawne nazwanie pól (`STRUCT(1 AS id, 'Anna' AS name)`) kosztuje niewiele więcej znaków, a eliminuje zgadywanie nazw pól przy dalszym odwoływaniu się do struktury w kolejnych krokach zapytania.

---

## Podsumowanie: słownik pojęć T-SQL → BigQuery

| T-SQL | BigQuery | Uwaga |
|---|---|---|
| Osobna tabela + `FOREIGN KEY` (relacja 1:N) | `ARRAY<STRUCT<...>>` w jednej kolumnie | Denormalizacja przez zagnieżdżenie zamiast `JOIN` |
| `JOIN` dwóch tabel | `CROSS JOIN UNNEST(kolumna)` | Spłaszczenie zagnieżdżonych danych do wierszy |
| `LEFT JOIN` (zachowanie wierszy bez dopasowania) | `LEFT JOIN UNNEST(kolumna)` | Zachowuje wiersze z pustą/`NULL` tablicą |
| `STRING_AGG(kolumna, ', ')` | `ARRAY_AGG(kolumna)` | Zwraca prawdziwą tablicę, nie tekst |
| `ROW_NUMBER() OVER (...) = 1` (dedup) | `ARRAY_AGG(... ORDER BY ... LIMIT 1)[OFFSET(0)]` | Alternatywny, funkcyjny idiom na to samo zadanie |
| Rekurencyjny CTE do generowania sekwencji dat | `GENERATE_DATE_ARRAY(start, end)` | Wbudowana funkcja, bez CTE |
| `STRING_SPLIT` | `SPLIT` | Zwraca `ARRAY`, nie tabelę jednokolumnową |
| Brak odpowiednika (typ złożony w kolumnie) | `STRUCT` | Zagnieżdżony rekord, dostęp przez `.pole` |
| Indeksowanie od 1 (np. `SUBSTRING`) | `[ORDINAL(n)]` (od 1) vs `[OFFSET(n)]` (od 0) | BigQuery ma OBA warianty — łatwo pomylić |

**Wniosek:** to nie jest "nowa składnia tych samych operacji" — to inny sposób modelowania relacji 1:N, wart potraktowania jako osobnej umiejętności, nie tylko innego dialektu SQL. Najbezpieczniejszy nawyk: przy każdej nowej tabeli publicznej sprawdź schemat (Receptura 6) PRZED napisaniem pierwszego zapytania — zagnieżdżone pola nie zawsze są oczywiste z samej nazwy kolumny.
