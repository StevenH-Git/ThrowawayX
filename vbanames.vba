' ===== Module: ModReplaceVars =====
Option Explicit

Public Sub ReplaceVariablesFromExcelRow()
    Dim fPath As String, rowNum As Long
    Dim xlApp As Object, wb As Object, ws As Object
    Dim PN As String, REV As String, TITLE As String, DESCRIPTION As String
    
    On Error GoTo Fail
    
    fPath = PickExcelPath_()
    If Len(fPath) = 0 Then Exit Sub
    
    rowNum = CLng(InputBox("Row number to read (1-based):", "Select Row"))
    If rowNum < 1 Then Exit Sub
    
    Set xlApp = CreateObject("Excel.Application")
    xlApp.Visible = False
    Set wb = xlApp.Workbooks.Open(fPath, False, True)
    Set ws = wb.Worksheets(1)
    
    PN = NzStr_(ws.Cells(rowNum, 1).Value)
    REV = NzStr_(ws.Cells(rowNum, 2).Value)
    TITLE = NzStr_(ws.Cells(rowNum, 3).Value)
    DESCRIPTION = NzStr_(ws.Cells(rowNum, 4).Value)
    
    ReplaceTokenEverywhere "$PN", PN
    ReplaceTokenEverywhere "$REV", REV
    ReplaceTokenEverywhere "$TITLE", TITLE
    ReplaceTokenEverywhere "$DESCRIPTION", DESCRIPTION
    
Clean:
    On Error Resume Next
    If Not wb Is Nothing Then wb.Close False
    If Not xlApp Is Nothing Then xlApp.Quit
    Set ws = Nothing: Set wb = Nothing: Set xlApp = Nothing
    Exit Sub
Fail:
    MsgBox "Variable merge failed: " & Err.Description, vbExclamation
    Resume Clean
End Sub

' ---------- replacement engine ----------

Private Sub ReplaceTokenEverywhere(ByVal token As String, ByVal valText As String)
    ' Main story + all linked stories (footnotes, endnotes, text frames, headers/footers)
    Dim rng As Range
    For Each rng In ActiveDocument.StoryRanges
        ReplaceInRange_ rng, token, valText
        ' follow linked stories
        Do While Not rng.NextStoryRange Is Nothing
            Set rng = rng.NextStoryRange
            ReplaceInRange_ rng, token, valText
        Loop
    Next rng
    
    ' Text in Shapes in body
    Dim shp As Shape
    For Each shp In ActiveDocument.Shapes
        If shp.TextFrame.HasText Then
            ReplaceInRange_ shp.TextFrame.TextRange, token, valText
        End If
    Next shp
    
    ' Shapes inside headers/footers
    Dim sec As Section, hf As HeaderFooter, shpHF As Shape
    For Each sec In ActiveDocument.Sections
        For Each hf In sec.Headers
            For Each shpHF In hf.Shapes
                If shpHF.TextFrame.HasText Then
                    ReplaceInRange_ shpHF.TextFrame.TextRange, token, valText
                End If
            Next shpHF
        Next hf
        For Each hf In sec.Footers
            For Each shpHF In hf.Shapes
                If shpHF.TextFrame.HasText Then
                    ReplaceInRange_ shpHF.TextFrame.TextRange, token, valText
                End If
            Next shpHF
        Next hf
    Next sec
End Sub

Private Sub ReplaceInRange_(ByVal target As Range, ByVal token As String, ByVal valText As String)
    With target.Find
        .ClearFormatting
        .Replacement.ClearFormatting
        .Text = token
        .Replacement.Text = valText
        .Forward = True
        .Wrap = wdFindStop
        .Format = False
        .MatchCase = False
        .MatchWholeWord = False
        .MatchByte = False
        .MatchWildcards = False
        .MatchSoundsLike = False
        .MatchAllWordForms = False
        .Execute Replace:=wdReplaceAll
    End With
End Sub

' ---------- helpers ----------

Private Function PickExcelPath_() As String
    Dim fd As FileDialog
    Set fd = Application.FileDialog(msoFileDialogFilePicker)
    With fd
        .Title = "Select Excel file"
        .AllowMultiSelect = False
        .Filters.Clear
        .Filters.Add "Excel", "*.xlsx;*.xlsm;*.xlsb;*.xls"
        If .Show = -1 Then PickExcelPath_ = .SelectedItems(1)
    End With
End Function

Private Function NzStr_(ByVal v As Variant) As String
    If IsError(v) Or IsNull(v) Or LenB(v) = 0 Then
        NzStr_ = ""
    Else
        NzStr_ = CStr(v)
    End If
End Function
