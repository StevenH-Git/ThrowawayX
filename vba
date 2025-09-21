Sub InsertExcelData()
    Dim ExcelApp As Object
    Dim ExcelWorkbook As Object
    Dim ExcelWorksheet As Object
    Dim WordRange As Range
    Dim LastRow As Long
    Dim i As Long
    Dim ExcelFilePath As String
    Dim WordTable As Table
    Dim TableBorders As Borders
    
    ExcelFilePath = "C:\path\Book1.xlsx"
    
    Set ExcelApp = CreateObject("Excel.Application")
    ExcelApp.Visible = False
    Set ExcelWorkbook = ExcelApp.Workbooks.Open(ExcelFilePath)
    Set ExcelWorksheet = ExcelWorkbook.Sheets(1)
    
    LastRow = ExcelWorksheet.Cells(ExcelWorksheet.Rows.Count, "A").End(-4162).Row
    
    Set WordRange = ActiveDocument.Range
    Set WordTable = ActiveDocument.Tables.Add(Range:=WordRange, NumRows:=LastRow - 1, NumColumns:=4)
    
    WordTable.Cell(1, 1).Range.Text = "Column A"
    WordTable.Cell(1, 2).Range.Text = "Column B"
    WordTable.Cell(1, 3).Range.Text = "Column C"
    WordTable.Cell(1, 4).Range.Text = "Empty"
    

    For i = 2 To LastRow
        WordTable.Cell(i - 1, 1).Range.Text = ExcelWorksheet.Cells(i, 1).Value
        WordTable.Cell(i - 1, 2).Range.Text = ExcelWorksheet.Cells(i, 2).Value
        WordTable.Cell(i - 1, 3).Range.Text = ExcelWorksheet.Cells(i, 3).Value
        WordTable.Cell(i - 1, 4).Range.Text = ""
    Next i
    Set TableBorders = WordTable.Borders
    With TableBorders
        .Enable = True
        .OutsideLineStyle = wdLineStyleSingle
        .InsideLineStyle = wdLineStyleSingle
        .InsideLineWidth = wdLineWidth050pt
        .OutsideLineWidth = wdLineWidth050pt
        
        .OutsideColor = wdColorBlack
        .InsideColor = wdColorBlack
    End With
    
    ExcelWorkbook.Close
    ExcelApp.Quit
    
    Set WordTable = Nothing
    Set TableBorders = Nothing
    Set ExcelWorksheet = Nothing
    Set ExcelWorkbook = Nothing
    Set ExcelApp = Nothing
End Sub

