-- 1. Przygotowanie danych
CREATE TABLE #SprzedazMiedzynarodowa (
    Miesiac VARCHAR(7), -- YYYY-MM
    Kraj VARCHAR(50),
    Przychod DECIMAL(15,2)
);

INSERT INTO #SprzedazMiedzynarodowa VALUES
('2026-01', 'Polska', 100000.00),
('2026-01', 'Niemcy', 250000.00),
('2026-01', 'Francja', 180000.00),
('2026-02', 'Polska', 120000.00),
('2026-02', 'Niemcy', 210000.00),
('2026-02', 'Hiszpania', 90000.00); -- Nowy kraj w lutym!

-- 2. Zmienne do zbudowania skryptu dynamicznego
DECLARE @PivotColumns NVARCHAR(MAX) = '';
DECLARE @SelectColumns NVARCHAR(MAX) = '';
DECLARE @SQLQuery NVARCHAR(MAX) = '';

-- A. Zbudowanie listy kolumn do klauzuli IN: [Francja],[Hiszpania],[Niemcy],[Polska]
SELECT @PivotColumns = STRING_AGG(QUOTENAME(Kraj), ',') WITHIN GROUP (ORDER BY Kraj)
FROM (SELECT DISTINCT Kraj FROM #SprzedazMiedzynarodowa) AS Kraje;

-- B. Zbudowanie listy kolumn z obsługą ISNULL([Kraj], 0) w zapytaniu SELECT
SELECT @SelectColumns = STRING_AGG(
    'ISNULL(' + QUOTENAME(Kraj) + ', 0) AS ' + QUOTENAME(Kraj), 
    ', '
) WITHIN GROUP (ORDER BY Kraj)
FROM (SELECT DISTINCT Kraj FROM #SprzedazMiedzynarodowa) AS Kraje;

-- C. Konstrukcja dynamicznego zapytania SQL
SET @SQLQuery = '
SELECT 
    Miesiac,
    ' + @SelectColumns + '
FROM (
    SELECT 
        Miesiac, 
        Kraj, 
        Przychod 
    FROM #SprzedazMiedzynarodowa
) AS Src
PIVOT (
    SUM(Przychod)
    FOR Kraj IN (' + @PivotColumns + ')
) AS Pvt
ORDER BY Miesiac;';

-- D. Podgląd wygenerowanego SQL (narzędzie do debugowania)
-- PRINT @SQLQuery; 

-- E. Wykonanie bezpiecznym punktem wejścia sp_executesql
EXEC sp_executesql @SQLQuery;
