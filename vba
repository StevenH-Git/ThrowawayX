Option Explicit

Sub MergeStepsFromExcel()
    Dim xlApp As Object, wb As Object, ws As Object
    Dim fPath As String, lastRow As Long, r As Long
    Dim typ As String, stepTxt As String, noteTxt As String
    
    Dim secIdx As Long, majIdx As Long, stpIdx As Long
    Dim doc As Document: Set doc = ActiveDocument
    Dim tgt As Range: Set tgt = GetInsertionRangeSafe(doc)
    
    Dim curTable As Table
    Dim firstRowPending As Boolean
    
    On Error GoTo CleanFail
    
    fPath = PickExcelPath(): If Len(fPath) = 0 Then Exit Sub
    Set xlApp = CreateObject("Excel.Application"): xlApp.Visible = False
    Set wb = xlApp.Workbooks.Open(fPath, False, True)
    Set ws = wb.Worksheets(1)
    lastRow = ws.Cells(ws.Rows.Count, 1).End(-4162).Row  ' xlUp
    
    secIdx = 0: majIdx = 0: stpIdx = 0
    Set curTable = Nothing: firstRowPending = False
    
    For r = 2 To lastRow
        typ = UCase$(Trim$(CStr(ws.Cells(r, 1).Value)))
        stepTxt = Trim$(CStr(Nz(ws.Cells(r, 2).Value, "")))
        noteTxt = Trim$(CStr(Nz(ws.Cells(r, 3).Value, "")))
        
        Select Case typ
            Case "START SECTION"
                If Not curTable Is Nothing Then FinalizeTable curTable, doc: Set curTable = Nothing
                majIdx = 0: stpIdx = 0
                secIdx = secIdx + 1
                InsertSectionHeader tgt, stepTxt
            
            Case "START MAJOR"
                If Not curTable Is Nothing Then FinalizeTable curTable, doc: Set curTable = Nothing
                majIdx = majIdx + 1: stpIdx = 0
                InsertMajorTitle tgt, stepTxt
                Set curTable = InsertNewTable4(tRange:=tgt, doc:=doc)
                StyleTableBorders curTable
                firstRowPending = True
            
            Case "STEP"
                If Not curTable Is Nothing Then
                    stpIdx = stpIdx + 1
                    If firstRowPending Then
                        FillStepRow curTable.Rows(1), secIdx, majIdx, stpIdx, stepTxt, noteTxt
                        firstRowPending = False
                    Else
                        Dim nr As Row
                        Set nr = curTable.Rows.Add
                        FillStepRow nr, secIdx, majIdx, stpIdx, stepTxt, noteTxt
                    End If
                End If
            
            Case "END MAJOR"
                If Not curTable Is Nothing Then FinalizeTable curTable, doc: Set curTable = Nothing
                firstRowPending = False
                AddSpacer tgt
            
            Case "NOTE"
                ' ignored
            
            Case "END SECTION"
                AddSpacer tgt
        End Select
    Next r
    
    If Not curTable Is Nothing Then FinalizeTable curTable, doc: Set curTable = Nothing

CleanOk:
    On Error Resume Next
    If Not wb Is Nothing Then wb.Close False
    If Not xlApp Is Nothing Then xlApp.Quit
    Exit Sub
CleanFail:
    MsgBox "Merge failed at row " & r & " (" & typ & "): " & Err.Description, vbExclamation
    Resume CleanOk
End Sub

' ---------- helpers ----------

Private Function PickExcelPath() As String
    Dim fd As FileDialog: Set fd = Application.FileDialog(msoFileDialogFilePicker)
    With fd
        .Title = "Select Steps.xlsx": .AllowMultiSelect = False
        .Filters.Clear: .Filters.Add "Excel", "*.xlsx;*.xlsm;*.xlsb;*.xls"
        If .Show = -1 Then PickExcelPath = .SelectedItems(1)
    End With
End Function

Private Function GetInsertionRangeSafe(ByVal doc As Document) As Range
    Dim r As Range
    If doc.Bookmarks.Exists("MERGE_ANCHOR") Then
        Set r = doc.Bookmarks("MERGE_ANCHOR").Range
    Else
        Set r = doc.Content: r.Collapse wdCollapseEnd
    End If
    If r.StoryType <> wdMainTextStory Then
        Set r = doc.StoryRanges(wdMainTextStory): r.Collapse wdCollapseEnd
    End If
    If r.Information(wdWithInTable) Then
        Set r = doc.Content: r.Collapse wdCollapseEnd
        r.InsertParagraphAfter: r.Collapse wdCollapseEnd
    End If
    Set GetInsertionRangeSafe = r
End Function

Private Sub InsertSectionHeader(ByRef tgt As Range, ByVal textVal As String)
    If Len(textVal) = 0 Then Exit Sub
    tgt.InsertParagraphAfter
    tgt.Collapse wdCollapseEnd
    tgt.Text = textVal
    With tgt.Paragraphs(1).Range
        .Font.Bold = True
        On Error Resume Next: .Style = wdStyleHeading2: On Error GoTo 0
    End With
    tgt.SetRange tgt.Paragraphs(1).Range.End, tgt.Paragraphs(1).Range.End
    AddSpacer tgt
End Sub

Private Sub InsertMajorTitle(ByRef tgt As Range, ByVal titleTxt As String)
    If Len(titleTxt) = 0 Then titleTxt = "Major"
    tgt.InsertParagraphAfter
    tgt.Collapse wdCollapseEnd
    tgt.Text = titleTxt
    With tgt.Paragraphs(1).Range
        .Font.Bold = True
        On Error Resume Next: .Style = wdStyleHeading3: On Error GoTo 0
    End With
    tgt.SetRange tgt.Paragraphs(1).Range.End, tgt.Paragraphs(1).Range.End
End Sub

Private Function InsertNewTable4(ByRef tRange As Range, ByVal doc As Document) As Table
    Dim tbl As Table
    tRange.InsertParagraphAfter
    tRange.Collapse wdCollapseEnd
    Set tbl = doc.Tables.Add(Range:=tRange, NumRows:=1, NumColumns:=4)
    ' Set a sane baseline width model in points to avoid overflow math
    With tbl
        .AllowAutoFit = False
        .PreferredWidthType = wdPreferredWidthPoints
        .PreferredWidth = PageContentWidth(doc)
        ' provisional widths that fit any page
        Dim w1 As Single, w4 As Single, w2 As Single, w3 As Single, totalW As Single
        w1 = Application.InchesToPoints(0.9)  ' fits X.Y.Z
        w4 = Application.InchesToPoints(0.5)  ' ~4 "X"
        totalW = .PreferredWidth
        If totalW < (w1 + w4 + Application.InchesToPoints(1)) Then
            ' extremely narrow: clamp fourth col
            w4 = Application.InchesToPoints(0.3)
        End If
        w2 = (totalW - w1 - w4) * 0.55
        w3 = totalW - w1 - w4 - w2
        On Error Resume Next
        .Columns(1).Width = w1
        .Columns(4).Width = IIf(w4 > 0, w4, Application.InchesToPoints(0.3))
        .Columns(2).Width = w2
        .Columns(3).Width = w3
        On Error GoTo 0
    End With
    Set InsertNewTable4 = tbl
    tRange.SetRange tbl.Range.End, tbl.Range.End
    ' ensure a paragraph after the table
    Dim aft As Range: Set aft = tbl.Range.Duplicate
    aft.Collapse wdCollapseEnd
    aft.InsertParagraphAfter
    tRange.SetRange aft.End, aft.End
End Function

Private Sub StyleTableBorders(ByVal tbl As Table)
    With tbl.Borders
        .OutsideLineStyle = wdLineStyleSingle
        .InsideLineStyle = wdLineStyleSingle
        .OutsideLineWidth = wdLineWidth050pt
        .InsideLineWidth = wdLineWidth050pt
        .OutsideColor = wdColorAutomatic
        .InsideColor = wdColorAutomatic
    End With
    tbl.Range.ParagraphFormat.SpaceBefore = 0
    tbl.Range.ParagraphFormat.SpaceAfter = 0
    tbl.Range.ParagraphFormat.Alignment = wdAlignParagraphLeft
End Sub

' Final sizing: reapply fixed point widths within page bounds. No AutoFit calls here.
Private Sub FinalizeTable(ByVal tbl As Table, ByVal doc As Document)
    If tbl Is Nothing Then Exit Sub
    If tbl.Columns.Count < 4 Then Exit Sub
    
    Dim contentW As Single: contentW = PageContentWidth(doc)
    Dim w1 As Single, w4 As Single, minBody As Single
    w1 = Application.InchesToPoints(0.9)
    w4 = Application.InchesToPoints(0.5)
    minBody = Application.InchesToPoints(1#)  ' minimum combined for cols 2+3
    
    If contentW < (w1 + w4 + minBody) Then
        ' shrink fourth column if needed
        w4 = Application.InchesToPoints(0.3)
        If contentW < (w1 + w4 + minBody) Then
            ' as a last resort also shrink col1 slightly
            w1 = Application.InchesToPoints(0.7)
        End If
    End If
    
    Dim w2 As Single, w3 As Single, bodyW As Single
    bodyW = contentW - w1 - w4
    If bodyW < Application.InchesToPoints(0.5) Then bodyW = Application.InchesToPoints(0.5)
    w2 = bodyW * 0.55
    w3 = bodyW - w2
    
    On Error Resume Next
    tbl.AllowAutoFit = False
    tbl.PreferredWidthType = wdPreferredWidthPoints
    tbl.PreferredWidth = contentW
    tbl.Columns(1).Width = w1
    tbl.Columns(4).Width = w4
    tbl.Columns(2).Width = w2
    tbl.Columns(3).Width = w3
    On Error GoTo 0
    
    StyleTableBorders tbl
End Sub

Private Function PageContentWidth(ByVal doc As Document) As Single
    With doc.PageSetup
        PageContentWidth = .PageWidth - .LeftMargin - .RightMargin
    End With
End Function

Private Sub FillStepRow(ByVal rw As Row, ByVal s As Long, ByVal m As Long, ByVal z As Long, ByVal stepTxt As String, ByVal noteTxt As String)
    SafeSetCell rw.Cells(1), s & "." & m & "." & z
    SafeSetCell rw.Cells(2), stepTxt
    SafeSetCell rw.Cells(3), noteTxt
    SafeSetCell rw.Cells(4), ""
End Sub

Private Sub SafeSetCell(ByVal c As Cell, ByVal txt As String)
    Dim r As Range: Set r = c.Range
    If r.End > r.Start Then r.End = r.End - 1  ' exclude end-of-cell marker
    r.Text = txt
End Sub

Private Sub AddSpacer(ByRef tgt As Range)
    tgt.InsertParagraphAfter
    tgt.Collapse wdCollapseEnd
End Sub

Private Function Nz(valIn As Variant, Optional defaultVal As String = "") As Variant
    If IsError(valIn) Then
        Nz = defaultVal
    ElseIf IsNull(valIn) Then
        Nz = defaultVal
    Else
        Nz = valIn
    End If
End Function
