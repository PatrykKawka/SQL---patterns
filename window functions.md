# Funkcje okienkowe w T-SQL — pełne kompendium

> **Uwaga metodologiczna:** większość przykładów w tym dokumencie została policzona na DuckDB (silnik z pełną, zgodną z ANSI SQL implementacją funkcji okienkowych) — nie na żywym SQL Server, do którego nie mam dostępu w tym środowisku. Składnia okienkowa (`OVER`, `PARTITION BY`, `ROWS`/`RANGE BETWEEN`, funkcje rankingowe) jest identyczna między T-SQL a ANSI SQL, więc wyniki liczbowe są wiarygodne. Jeden wyjątek jest jawnie oznaczony niżej (`PERCENTILE_CONT` jako funkcja okienkowa) — tego fragmentu nie dało się przeliczyć w tym środowisku, opisuję go na podstawie udokumentowanego zachowania T-SQL.

## Wprowadzenie: czym różni się funkcja okienkowa od `GROUP BY`

`GROUP BY` REDUKUJE liczbę wierszy — N wierszy wejściowych staje się M wierszy wyjściowych (po jednym na grupę). Funkcja okienkowa (`OVER (...)`) **nie redukuje niczego** — każdy wiersz wejściowy zostaje w wyniku, ale dodatkowo "widzi" powiązane z nim wiersze (swoje "okno") i może się do nich odwołać. To pozwala policzyć np. "ranking tego wiersza w obrębie regionu" bez utraty pozostałych kolumn tego wiersza — czego zwykły `GROUP BY` nie potrafi bez dodatkowego `JOIN`-a z powrotem do tabeli źródłowej.

### Anatomia klauzuli `OVER`

```sql
funkcja() OVER (
    PARTITION BY kolumna1, kolumna2   -- opcjonalne: dzieli dane na niezależne "partycje"
    ORDER BY kolumna3                  -- opcjonalne: kolejność w obrębie okna
    ROWS/RANGE BETWEEN ... AND ...     -- opcjonalne: dokładna "ramka" względem bieżącego wiersza
)
```

Wszystkie trzy elementy są opcjonalne i niezależne od siebie — ale ich **obecność zmienia domyślne zachowanie** w sposób, który jest źródłem większości pułapek w tym dokumencie (patrz Część 4).

---

## Część 1 — Funkcje rankingowe

### 1.1–1.3 `ROW_NUMBER`, `RANK`, `DENSE_RANK` — trzy różne odpowiedzi na remis

Wszystkie trzy numerują wiersze wg `ORDER BY`, ale **różnią się zachowaniem przy remisie** (dwóch wierszach o identycznej wartości sortującej):

```sql
SELECT salesperson, region, amount,
    ROW_NUMBER() OVER (ORDER BY amount DESC) AS rn,
    RANK()       OVER (ORDER BY amount DESC) AS rnk,
    DENSE_RANK() OVER (ORDER BY amount DESC) AS drnk
FROM sales
ORDER BY amount DESC;
```

**Zweryfikowany wynik** (Celina i Dawid mają remis po 1500, Anna ma dwie transakcje po 1200):

| salesperson | amount | rn | rnk | drnk |
|---|---|---|---|---|
| Celina | 1500 | 1 | 1 | 1 |
| Dawid | 1500 | 2 | 1 | 1 |
| Anna | 1200 | 3 | 3 | 2 |
| Anna | 1200 | 4 | 3 | 2 |
| Bartek | 950 | 5 | 5 | 3 |

- **`ROW_NUMBER`** — zawsze unikalny numer, remisy rozstrzygane arbitralnie wg kolejności fizycznej/dodatkowych kolumn.
- **`RANK`** — remisy dostają TEN SAM ranking, a numeracja robi "dziurę" po nich (`1, 1, 3` — nie ma `2`).
- **`DENSE_RANK`** — remisy dostają ten sam ranking, ale BEZ dziury (`1, 1, 2`).

**Praktyczne zastosowanie:** `RANK` do prawdziwego rankingu sportowego/sprzedażowego (gdzie "dziura" po remisie jest matematycznie poprawna — dwóch na 1. miejscu oznacza, że kolejny jest na 3.). `DENSE_RANK` do numerowania "poziomów" (np. kwintyle cenowe, gdzie chcesz kolejne liczby całkowite bez dziur). `ROW_NUMBER` wszędzie tam, gdzie potrzebujesz gwarancji unikalności — najczęściej: paginacja i deduplikacja (Część 5).

### 1.4 `NTILE(n)` — podział na `n` grup o zbliżonej liczności

```sql
SELECT salesperson, amount, NTILE(3) OVER (ORDER BY amount DESC) AS tercile
FROM sales;
```

**Zweryfikowany wynik:** przy 7 wierszach i `NTILE(3)`, grupy dostają 3/2/2 wiersze (nadwyżka trafia do pierwszych grup). **Praktyczne zastosowanie:** segmentacja klientów na tercyle/kwartyle/decyle wartości — częsty krok w analizie RFM czy przygotowaniu danych pod raport w Power BI.

---

## Część 2 — Funkcje przesunięcia (`LAG`/`LEAD`/`FIRST_VALUE`/`LAST_VALUE`)

### 2.1–2.2 `LAG`/`LEAD` — wartość N wierszy wstecz/w przód

```sql
SELECT salesperson, sale_date, amount,
    LAG(amount, 1, 0) OVER (PARTITION BY salesperson ORDER BY sale_date) AS prev_amount
FROM sales;
```

Trzeci argument (`0`) to **wartość domyślna** dla wierszy, które nie mają poprzednika (pierwszy wiersz w każdej partycji) — zweryfikowane: bez trzeciego argumentu dostałbyś tam `NULL`, z nim dostajesz jawne `0`. To ważne, jeśli dalej robisz na wyniku arytmetykę (`amount - prev_amount`) — odejmowanie od `NULL` samo w sobie daje `NULL`, co cicho zepsułoby dalsze obliczenia bez jawnej wartości domyślnej.

**Praktyczne zastosowanie:** analiza rok-do-roku/miesiąc-do-miesiąca (`LAG(amount, 12)` przy danych miesięcznych), wykrywanie pierwszego zamówienia klienta (`LAG(...) IS NULL`), obliczanie zmiany między kolejnymi zdarzeniami.

### 2.3 `FIRST_VALUE`/`LAST_VALUE` — **najważniejsza pułapka w tym dokumencie**

```sql
SELECT salesperson, region, sale_date, amount,
    FIRST_VALUE(amount) OVER (PARTITION BY region ORDER BY sale_date) AS first_val,
    LAST_VALUE(amount)  OVER (PARTITION BY region ORDER BY sale_date) AS last_val_wrong,
    LAST_VALUE(amount)  OVER (
        PARTITION BY region ORDER BY sale_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_val_correct
FROM sales
ORDER BY region, sale_date;
```

**Zweryfikowany wynik dla regionu North** (Anna 5.01 → 1200, Bartek 8.01 → 950):

| salesperson | sale_date | amount | first_val | last_val_wrong | last_val_correct |
|---|---|---|---|---|---|
| Anna | 5.01 | 1200 | 1200 | **1200** | 950 |
| Bartek | 8.01 | 950 | 1200 | 950 | 950 |

Dla Anny `last_val_wrong` zwraca **jej własną wartość (1200)**, nie faktyczną ostatnią wartość w partycji (950)! To dlatego, że `LAST_VALUE` bez jawnej ramki dziedziczy domyślną ramkę `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (patrz Część 4.3) — czyli "ostatnia wartość widziana DO TEJ PORY", nie "ostatnia wartość w całym oknie". Rozwiązanie: **zawsze** jawna ramka `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` przy `LAST_VALUE`.

---

## Część 3 — Agregaty okienkowe (`SUM`/`AVG`/`COUNT`/`MIN`/`MAX` z `OVER`)

Ten sam agregat, w zależności od obecności `ORDER BY` w `OVER`, liczy zupełnie różną rzecz:

```sql
-- Bez ORDER BY: suma CAŁEJ partycji, identyczna na każdym wierszu
SELECT salesperson, region, amount,
    SUM(amount) OVER (PARTITION BY region) AS region_total
FROM sales;

-- Z ORDER BY: suma NARASTAJĄCA (running total) do bieżącego wiersza włącznie
SELECT salesperson, region, sale_date, amount,
    SUM(amount) OVER (PARTITION BY region ORDER BY sale_date) AS running_total
FROM sales;
```

**Praktyczne zastosowanie:** `region_total` (bez `ORDER BY`) do policzenia `% udziału wiersza w całości partycji` (`amount / region_total`) — jeden agregat okienkowy zamiast osobnego zapytania z `GROUP BY` + `JOIN` z powrotem. `running_total` (z `ORDER BY`) do klasycznego running total sprzedaży w czasie.

---

## Część 4 — Ramki: `ROWS` vs `RANGE`, `UNBOUNDED`, domyślne zachowanie

### 4.1 Składnia ramki

```sql
ROWS/RANGE BETWEEN <punkt_start> AND <punkt_koniec>

-- gdzie <punkt> to jedno z:
UNBOUNDED PRECEDING   -- od samego początku partycji
N PRECEDING            -- N wierszy/wartości przed bieżącym
CURRENT ROW             -- bieżący wiersz
N FOLLOWING             -- N wierszy/wartości po bieżącym
UNBOUNDED FOLLOWING     -- do samego końca partycji
```

### 4.2 `ROWS` vs `RANGE` — kluczowa, często mylona różnica

- **`ROWS`** liczy FIZYCZNE wiersze — "2 wiersze wstecz" to zawsze dokładnie 2 wiersze, niezależnie od ich wartości.
- **`RANGE`** liczy wg WARTOŚCI w `ORDER BY` — przy remisie (kilku wierszach o tej samej wartości sortującej) `RANGE` traktuje je jako JEDNĄ "grupę równorzędną" i obejmuje wszystkie naraz.

**Zweryfikowany, dramatyczny przykład** (Dawid i Ewa mają remis po 900):

```sql
SELECT salesperson, amount,
    SUM(amount) OVER (ORDER BY amount ROWS  BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_rows,
    SUM(amount) OVER (ORDER BY amount RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_range
FROM sales
ORDER BY amount;
```

| salesperson | amount | running_rows | running_range |
|---|---|---|---|
| Filip | 700 | 700 | 700 |
| Dawid | 900 | 1600 | **2500** |
| Ewa | 900 | 2500 | **2500** |

Przy `ROWS`, Dawid i Ewa dostają RÓŻNE running totale (1600, potem 2500) — bo `ROWS` liczy dosłownie "wiersze do tej pory", niezależnie że mają tę samą wartość. Przy `RANGE`, OBAJ dostają 2500 — bo `RANGE` widzi ich jako jedną "grupę remisu" i przypisuje obu sumę WŁĄCZNIE z partnerem remisu. Jeśli Twój running total ma dawać unikalną, narastającą wartość na każdym wierszu (typowy oczekiwany efekt) — **potrzebujesz `ROWS`, nie `RANGE`** (albo dopisania kolumny łamiącej remis do `ORDER BY`, np. klucza unikalnego).

### 4.3 Domyślna ramka, gdy JEST `ORDER BY` (ale brak jawnego `ROWS`/`RANGE`)

**Zweryfikowane:** brak jawnej ramki przy obecności `ORDER BY` domyślnie oznacza `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — dokładnie to źródło pułapki z `LAST_VALUE` (Część 2.3) i źródło "niejawnego RANGE zamiast ROWS" z Części 4.2.

### 4.4 Domyślna ramka, gdy NIE MA `ORDER BY`

**Zweryfikowane:** brak `ORDER BY` w ogóle oznacza domyślnie całą partycję (`RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`) — dlatego `SUM(amount) OVER (PARTITION BY region)` bez `ORDER BY` daje tę samą wartość (sumę całej partycji) na każdym wierszu, zamiast running total.

### 4.5 Ramka WYCHODZĄCA poza partycję — automatyczne przycięcie, nie błąd

**Zweryfikowane** na 3-dniowej średniej kroczącej: pierwszy wiersz partycji, dla którego `2 PRECEDING` sięgałoby "przed początek danych", po prostu dostaje mniej wierszy w oknie (1, potem 2, dopiero od 3. wiersza pełne 3) — bez błędu i bez `NULL`. Warto to świadomie zaakceptować albo jawnie obsłużyć (np. `WHERE rn >= 3`, jeśli chcesz tylko w pełni ukształtowane okna).

---

## Część 5 — Gotowe receptury

### Receptura 1 — Top-N wierszy per grupa (T-SQL nie ma `QUALIFY`!)

**Ważna różnica względem BigQuery/DuckDB:** oba te dialekty mają klauzulę `QUALIFY`, pozwalającą filtrować bezpośrednio po funkcji okienkowej bez podzapytania. **T-SQL tego nie ma** — jedyna droga to owinięcie w podzapytanie/CTE:

```sql
SELECT * FROM (
    SELECT salesperson, region, amount,
        ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount DESC) AS rn
    FROM sales
) ranked
WHERE rn <= 2;
```

### Receptura 2 — Deduplikacja: najnowszy rekord per klucz

Klasyczny idiom "zachowaj tylko najnowszy wiersz na `customer_id`":

```sql
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) AS rn
    FROM customer_updates
)
SELECT customer_id, email, updated_at FROM ranked WHERE rn = 1;
```

**Zweryfikowane:** dla klienta z dwoma aktualizacjami (stary e-mail 1.01, nowy e-mail 15.01) recepta poprawnie zwraca tylko wiersz z 15.01. Ten sam wzorzec z `DELETE FROM ranked WHERE rn > 1` (na CTE) to standardowy sposób usuwania duplikatów w T-SQL.

### Receptura 3 — Gaps and islands: wykrywanie ciągłych sekwencji

Zadanie: znajdź nieprzerwane serie dni logowania użytkownika. Trik: `data − ROW_NUMBER()` jest STAŁA w obrębie każdej ciągłej sekwencji dat (bo obie rosną o 1 w tym samym tempie podczas serii, a "urywają się" inaczej po przerwie).

```sql
WITH numbered AS (
    SELECT user_id, login_date,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY login_date) AS rn
    FROM logins
),
grouped AS (
    SELECT user_id, login_date,
        login_date - CAST(rn AS INT) AS island_id
    FROM numbered
)
SELECT user_id, MIN(login_date) AS streak_start, MAX(login_date) AS streak_end, COUNT(*) AS streak_length
FROM grouped
GROUP BY user_id, island_id
ORDER BY streak_start;
```

**Zweryfikowane** na danych z lukami (logowania 1–3.01, przerwa, 5–6.01, przerwa, 10.01): recepta poprawnie wykrywa dokładnie trzy serie — (1–3.01, długość 3), (5–6.01, długość 2), (10.01, długość 1).

### Receptura 4 — `PERCENT_RANK` i `CUME_DIST`: pozycja względna w rozkładzie

Rzadziej używane, ale przydatne do "który percentyl zajmuje ten wiersz":

```sql
SELECT region, amount,
    PERCENT_RANK() OVER (ORDER BY amount) AS pct_rank,   -- (ranking-1)/(N-1), zakres 0..1
    CUME_DIST()    OVER (ORDER BY amount) AS cume_dist   -- % wierszy <= bieżącej wartości
FROM sales
ORDER BY amount;
```

**Zweryfikowane:** dla najniższej wartości w zbiorze `pct_rank = 0.0`, dla najwyższej `pct_rank` zbliża się do `1.0`; `cume_dist` dla wartości występującej wielokrotnie (remis) pokazuje tę samą, najwyższą wartość dla WSZYSTKICH wierszy remisu — inaczej niż `PERCENT_RANK`.

### Receptura 5 — Mediana per grupa: `PERCENTILE_CONT ... WITHIN GROUP (...) OVER (...)`

**Nie zweryfikowane w tym środowisku** (DuckDB nie ma tej funkcji pod nazwą `PERCENTILE_CONT`) — opisane na podstawie udokumentowanego zachowania T-SQL. W przeciwieństwie do zwykłych funkcji okienkowych, `PERCENTILE_CONT` łączy dwie klauzule: `WITHIN GROUP (ORDER BY ...)` (definiuje, po czym liczyć percentyl) i opcjonalnie `OVER (PARTITION BY ...)` (żeby policzyć osobną medianę per grupa, z wynikiem powtórzonym na każdym wierszu grupy — jak zwykły agregat okienkowy):

```sql
SELECT DISTINCT region,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY amount) OVER (PARTITION BY region) AS median_per_region
FROM sales;
```

Zanim użyjesz tego w produkcji, zweryfikuj na realnym SQL Server — składnia jest udokumentowana i stabilna, ale nie miałem możliwości przeliczyć jej w tej sesji.

---

## Część 6 — Pułapki (podsumowanie)

1. **`LAST_VALUE` bez jawnej ramki `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`** — zwraca "ostatnią wartość do tej pory", nie faktyczną ostatnią wartość okna. Najgroźniejsza pułapka w tym dokumencie — kod wygląda poprawnie i "coś" zwraca, ale to coś jest błędne (Część 2.3).
2. **`RANGE` zamiast `ROWS` przy remisach w `ORDER BY`** — running total "skleja" wiersze o tej samej wartości sortującej w jedną grupę zamiast liczyć je osobno (Część 4.2).
3. **Domyślna ramka `RANGE ... CURRENT ROW` aktywuje się cicho**, gdy tylko dodasz `ORDER BY` do `OVER` bez jawnej ramki — źródło obu powyższych pułapek naraz.
4. **Brak `QUALIFY` w T-SQL** — nie da się filtrować bezpośrednio po wyniku funkcji okienkowej w `WHERE`; zawsze potrzebne podzapytanie/CTE (Receptura 1). Próba `WHERE ROW_NUMBER() OVER (...) = 1` w tej samej klauzuli `SELECT` co samo wyliczenie da błąd składni — okienkowe nie mogą być użyte w `WHERE` tego samego poziomu zapytania.
5. **`PARTITION BY` bez `ORDER BY` + agregat** — zwraca sumę/średnią CAŁEJ partycji na każdym wierszu, nie running total. Czasem to zamierzone (% udziału w całości), czasem pomyłka zamiast prawdziwego running total (który wymaga `ORDER BY`).
6. **Wydajność na dużych tabelach** — funkcje okienkowe z `PARTITION BY`/`ORDER BY` wymagają posortowania danych; bez wspierającego indeksu na tych kolumnach silnik dokłada osobny operator sortowania w planie wykonania, co przy dużych tabelach bywa najdroższym elementem całego zapytania. Warto to sprawdzić w planie wykonania (`SET STATISTICS IO ON` / graficzny plan wykonania), zanim uzna się okienkowe za "za wolne" — częściej problemem jest brakujący indeks, nie sama funkcja okienkowa.

---

## Podsumowanie: pełna lista funkcji

| Funkcja | Co robi | Kluczowa uwaga |
|---|---|---|
| `ROW_NUMBER()` | Unikalny numer wiersza | Zawsze różny, nawet przy remisie |
| `RANK()` | Ranking z "dziurą" po remisie | `1,1,3` |
| `DENSE_RANK()` | Ranking bez dziury po remisie | `1,1,2` |
| `NTILE(n)` | Podział na `n` grup o zbliżonej liczności | Segmentacja/kwantyle |
| `LAG(col, n, default)` | Wartość `n` wierszy wstecz | Trzeci argument ratuje przed `NULL` na starcie partycji |
| `LEAD(col, n, default)` | Wartość `n` wierszy do przodu | Symetryczne do `LAG` |
| `FIRST_VALUE(col)` | Pierwsza wartość w oknie | Bezpieczna bez dodatkowych zastrzeżeń |
| `LAST_VALUE(col)` | Ostatnia wartość w oknie | **Zawsze** z jawną ramką `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` |
| `SUM`/`AVG`/`COUNT`/`MIN`/`MAX` `OVER (...)` | Agregat okienkowy | Zachowanie zależy od obecności `ORDER BY` — patrz Część 3 |
| `PERCENT_RANK()` | Pozycja względna w rozkładzie, 0–1 | `(ranking-1)/(N-1)` |
| `CUME_DIST()` | % wierszy ≤ bieżącej wartości | Remisy dostają tę samą, najwyższą wartość |
| `PERCENTILE_CONT(p) WITHIN GROUP (...)` | Percentyl/mediana | Może działać z `OVER (PARTITION BY ...)` jako okienkowa |

**Wniosek:** ten sam motyw co w innych notatkach tego repo — najgroźniejsze pułapki (`LAST_VALUE`, `RANGE` na remisach) nie rzucają błędu składniowego. Zapytanie się wykonuje i zwraca liczby, które wyglądają wiarygodnie. Jedyna obrona to znajomość DOMYŚLNYCH zachowań `OVER` (Część 4.3–4.4) na tyle dobrze, żeby wiedzieć, kiedy koniecznie trzeba nadpisać je jawną ramką.
