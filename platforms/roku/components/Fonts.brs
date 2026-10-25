' Type: the system face, regular or bold, at the sizes the design uses. Each spec is [node id, field, bold, size].
' A predefined system font is assigned first, then resized; the assignment gives each node its own Font node.
sub AirwaveApplyFonts(specs as object)
    for each spec in specs
        node = m.top.findNode(spec[0])
        face = "font:MediumSystemFont"
        if spec[2] then face = "font:MediumBoldSystemFont"
        if node <> invalid
            if spec[1] = "font"
                node.font = face
                node.font.size = spec[3]
            else if spec[1] = "focusedFont"
                node.focusedFont = face
                node.focusedFont.size = spec[3]
            else if spec[1] = "rowLabelFont"
                node.rowLabelFont = face
                node.rowLabelFont.size = spec[3]
            end if
        end if
    end for
end sub
