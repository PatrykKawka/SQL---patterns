CREATE VIEW vw_dim_baza_kadrowa_SCD2 AS
WITH DatesNormalized AS (
    SELECT 
        [Numer osobowy], [Nazwisko i imię], [Nazwa oddziału], [Stanowisko],
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
GlobalMaxDate AS (
    SELECT MAX(SnapshotMonth) AS MaxGlobalMonth FROM DatesNormalized
),
EmployeeLastMonth AS (
    -- Faktyczny ostatni miesiąc, w którym pracownik JAKKOLWIEK wystąpił w bazie
    -- (niezależnie od tego, czy to był miesiąc ze zmianą, czy stabilny)
    SELECT [Numer osobowy], MAX(SnapshotMonth) AS LastKnownMonth
    FROM DatesNormalized
    GROUP BY [Numer osobowy]
),
TrackChanges AS (
    SELECT 
        n.[Numer osobowy], n.[Nazwisko i imię], n.[Nazwa oddziału], n.[Stanowisko],
        n.SnapshotMonth AS ValidFrom, n.RowHash,
        LAG(n.RowHash) OVER ( PARTITION BY n.[Numer osobowy] ORDER BY n.SnapshotMonth ) AS PrevHash
    FROM DatesNormalized n
),
FilteredChanges AS (
    SELECT [Numer osobowy], [Nazwisko i imię], [Nazwa oddziału], [Stanowisko], ValidFrom
    FROM TrackChanges
    WHERE RowHash <> PrevHash OR PrevHash IS NULL
)
SELECT 
    f.[Numer osobowy],
    f.[Nazwisko i imię],
    f.[Nazwa oddziału],
    f.[Stanowisko],
    f.ValidFrom,
    CASE 
        WHEN LEAD(f.ValidFrom) OVER (PARTITION BY f.[Numer osobowy] ORDER BY f.ValidFrom) IS NOT NULL 
            THEN DATEADD(day, -1, LEAD(f.ValidFrom) OVER (PARTITION BY f.[Numer osobowy] ORDER BY f.ValidFrom))
        WHEN e.LastKnownMonth = g.MaxGlobalMonth 
            THEN CAST('2099-12-31' AS DATE)
        ELSE EOMONTH(e.LastKnownMonth)
    END AS ValidTo,
    CASE 
        WHEN LEAD(f.ValidFrom) OVER (PARTITION BY f.[Numer osobowy] ORDER BY f.ValidFrom) IS NULL
             AND e.LastKnownMonth = g.MaxGlobalMonth 
            THEN 1 
        ELSE 0 
    END AS IsCurrent
FROM FilteredChanges f
JOIN EmployeeLastMonth e ON f.[Numer osobowy] = e.[Numer osobowy]
CROSS JOIN GlobalMaxDate g;
