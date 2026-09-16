CREATE VIEW vw_dim_baza_kadrowa_SCD2 AS
WITH DatesNormalized AS (
    -- KROK 1: Normalizacja daty bazy do 1-go dnia miesiąca oraz wyliczenie HASH
    SELECT 
        [Numer osobowy],
        [Nazwisko i imię],
        [Nazwa oddziału],
        [Stanowisko],
        DATEFROMPARTS(YEAR([Data bazy]), MONTH([Data bazy]), 1) AS SnapshotMonth,
        HASHBYTES(
            'SHA2_256', 
            CONCAT(
                ISNULL([Nazwisko i imię], ''), '|',
                ISNULL([Nazwa oddziału], ''), '|',
                ISNULL([Stanowisko], '')
            )
        ) AS RowHash
    FROM dbo.dim_baza_kadrowa
),
FullCalendar AS (
    -- KROK 2: Unikalne daty baz w całej firmie
    SELECT DISTINCT SnapshotMonth FROM DatesNormalized
),
GlobalMaxDate AS (
    -- Wyznaczenie daty OSTATNIEJ znanej bazy w całej organizacji
    SELECT MAX(SnapshotMonth) AS MaxGlobalMonth FROM FullCalendar
),
TrackChanges AS (
    -- KROK 3: Wykrywanie zmian oraz zwolnień (porównanie z kalendarzem globalnym)
    SELECT 
        n.[Numer osobowy],
        n.[Nazwisko i imię],
        n.[Nazwa oddziału],
        n.[Stanowisko],
        n.SnapshotMonth AS ValidFrom,
        n.RowHash,
        LAG(n.RowHash) OVER (
            PARTITION BY n.[Numer osobowy] 
            ORDER BY n.SnapshotMonth
        ) AS PrevHash,
        LEAD(n.SnapshotMonth) OVER (
            PARTITION BY n.[Numer osobowy] 
            ORDER BY n.SnapshotMonth
        ) AS NextWorkerMonth,
        LEAD(c.SnapshotMonth) OVER (
            ORDER BY c.SnapshotMonth
        ) AS NextGlobalMonth,
        g.MaxGlobalMonth
    FROM DatesNormalized n
    LEFT JOIN FullCalendar c ON n.SnapshotMonth = c.SnapshotMonth
    CROSS JOIN GlobalMaxDate g
),
FilteredChanges AS (
    -- KROK 4: Zachowanie tylko faktycznych zmian w danych
    SELECT 
        [Numer osobowy],
        [Nazwisko i imię],
        [Nazwa oddziału],
        [Stanowisko],
        ValidFrom,
        NextWorkerMonth,
        NextGlobalMonth,
        MaxGlobalMonth
    FROM TrackChanges
    WHERE RowHash <> PrevHash 
       OR PrevHash IS NULL
)
-- KROK 5: Ostateczne wyznaczenie ValidFrom, ValidTo oraz IsCurrent
SELECT 
    [Numer osobowy],
    [Nazwisko i imię],
    [Nazwa oddziału],
    [Stanowisko],
    ValidFrom,
    
    -- OŚ CZASU ValidTo:
    CASE 
        -- A) Nastąpiła kolejna zmiana w danych -> zmiana kończy się w dniu poprzedzającym nowy ValidFrom
        WHEN LEAD(ValidFrom) OVER (PARTITION BY [Numer osobowy] ORDER BY ValidFrom) IS NOT NULL 
            THEN DATEADD(day, -1, LEAD(ValidFrom) OVER (PARTITION BY [Numer osobowy] ORDER BY ValidFrom))
        
        -- B) Pracownik zniknął (ostatnia jego baza jest wcześniejsza niż ostatnia baza firmy) 
        --    -> ValidTo = Koniec miesiąca jego ostatniej bazy
        WHEN NextWorkerMonth IS NULL AND ValidFrom < MaxGlobalMonth 
            THEN EOMONTH(ValidFrom)
            
        -- C) Obecny pracownik -> Data z przyszłości
        ELSE CAST('9999-12-31' AS DATE)
    END AS ValidTo,

    -- STATUS IsCurrent:
    CASE 
        -- Aktualny pracownik (brak nowszych baz i był w ostatniej bazie firmy)
        WHEN NextWorkerMonth IS NULL AND ValidFrom = MaxGlobalMonth THEN 1 
        -- Zwolniony lub historyczny rekord
        ELSE 0 
    END AS IsCurrent

FROM FilteredChanges;
