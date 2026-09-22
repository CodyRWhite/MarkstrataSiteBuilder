<#
    Web part helpers. The Markstrata package installs MORE THAN ONE component - "Markstrata -
    Markdown" and "Markstrata - HTML" - so the component a page is built with has to be chosen
    deliberately and by something stable.

    markdownPage.componentId is that something: a GUID, identical in every tenant, and unambiguous
    between the two components. componentName is a display name - it has already changed once, and
    a bare "Markstrata" now matches neither component.

    The reason this matters more than a tidier lookup: Add-PnPPageWebPart -Component does NOT throw
    when nothing matches. It adds a control with the properties set and an EMPTY WebPartId, leaving
    SharePoint with no component to instantiate. The page renders blank and the command reports
    success, so a whole library can publish "successfully" as blank pages. Every page build
    therefore resolves the component to an OBJECT first, and asserts afterwards that a web part is
    really attached.

    -Component accepts a component name or a resolved component object. It does NOT accept a GUID
    string: passing one fails in exactly the same silent way, which is why the id is looked up
    through Get-PnPAvailablePageComponents rather than handed over directly.
#>

function Resolve-MarkstrataComponent {
    <#
    .SYNOPSIS
        Resolve the configured web part to the component object Add-PnPPageWebPart needs.

    .DESCRIPTION
        Matches markdownPage.componentId against the components available on the site, falling back
        to markdownPage.componentName when the id matches nothing - an older package, or a component
        whose GUID was never recorded in config.

        Both sides of the id comparison are normalised: the API returns "{74AECD51-...}" while the
        config holds "74aecd51-...", so braces and case are stripped before comparing.

        A name that matches MORE than one component is an error rather than a guess. That is the
        situation this module was in with a bare "Markstrata" against two installed components, and
        picking the first would have built the whole library with whichever one happened to sort
        first.

        The result is cached for the session: the components available to a site do not change
        mid-run, so this costs one round trip per run rather than one per page. Disconnecting clears
        the cache, because the next site may have a different set installed.

    .PARAMETER Page
        An EXISTING page to enumerate against. Get-PnPAvailablePageComponents lists what is
        available to a specific page, so it needs one that is already there - normally the page just
        created by the caller.

    .PARAMETER ComponentId
        Build with THIS component instead of the configured one, for a single run. A site that keeps
        some documents on one component and some on the other would otherwise need a config edit
        between runs. An explicit id never falls back to componentName: naming a component
        deliberately and silently getting a different one is worse than failing.

    .OUTPUTS
        The component object, ready to pass to Add-PnPPageWebPart -Component.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Page,

        [string]$ComponentId = ""
    )

    $config = Get-MarkstrataConfig
    $explicit = [bool]$ComponentId
    if ($explicit) {
        $wantedId = $ComponentId.Trim().Trim("{}").ToLowerInvariant()
        $wantedName = ""
    }
    else {
        $wantedId = (([string](Get-OptionalProperty $config.MarkdownPage "componentId" "")).Trim()).Trim("{}").ToLowerInvariant()
        $wantedName = ([string](Get-OptionalProperty $config.MarkdownPage "componentName" "")).Trim()
    }

    if (-not $wantedId -and -not $wantedName) {
        throw "Neither markdownPage.componentId nor markdownPage.componentName is set, so there is no web part to build with."
    }

    # The cache is keyed on what was asked for, not just "something was resolved once". Two runs in
    # one session can now ask for different components, and returning the first would build the
    # second run's pages with the wrong web part - silently, since both attach perfectly well.
    $cacheKey = if ($wantedId) { "id:$wantedId" } else { "name:$wantedName" }
    if ($script:ResolvedComponent -and $script:ResolvedComponentKey -eq $cacheKey) {
        return $script:ResolvedComponent
    }

    $available = @(Get-PnPAvailablePageComponents -Page $Page -ErrorAction Stop)

    $match = $null
    if ($wantedId) {
        $match = $available |
            Where-Object { (([string](Get-OptionalProperty $_ "Id" "")).Trim("{}").ToLowerInvariant()) -eq $wantedId } |
            Select-Object -First 1
    }

    if (-not $match -and $wantedName -and -not $explicit) {
        $byName = @($available | Where-Object { [string](Get-OptionalProperty $_ "Name" "") -eq $wantedName })
        if ($byName.Count -gt 1) {
            throw "componentName '$wantedName' matches $($byName.Count) components on this site. Set markdownPage.componentId to the GUID of the one you want."
        }
        if ($byName.Count -eq 1) {
            $match = $byName[0]
            Write-MarkstrataLog -Message "componentId '$wantedId' matched nothing; fell back to componentName '$wantedName'. Record its id in config to make this stable." -Level Warning -Component "Page"
        }
    }

    if (-not $match) {
        # The names actually installed are the one thing that makes this fixable, so they go in the
        # message rather than only in the log.
        $installed = @($available |
            Where-Object { [string](Get-OptionalProperty $_ "Name" "") -like "*Markstrata*" } |
            ForEach-Object { "{0} ({1})" -f (Get-OptionalProperty $_ "Name" ""), (Get-OptionalProperty $_ "Id" "") })
        $detail = if ($installed.Count -gt 0) { $installed -join "; " } else { "none - the package is not added to this site" }
        $asked = if ($explicit) { "-ComponentId '$wantedId'" } else { "componentId '$wantedId' or componentName '$wantedName'" }
        throw "No web part matches $asked. Markstrata components on this site: $detail"
    }

    Write-MarkstrataLog -Message "Resolved web part: $(Get-OptionalProperty $match 'Name' '') ($(Get-OptionalProperty $match 'Id' ''))" -Component "Page" -NoConsole
    $script:ResolvedComponent = $match
    $script:ResolvedComponentKey = $cacheKey
    return $match
}

function Assert-MarkstrataWebPart {
    <#
    .SYNOPSIS
        Fail when a page's web part did not actually attach.

    .DESCRIPTION
        This is the check that turns a blank page into an error. Add-PnPPageWebPart reports success
        whether or not it matched a component; the difference shows up only on the saved page, as a
        control with an empty WebPartId. SharePoint then has nothing to instantiate and the page
        renders empty, which is indistinguishable from a working page until somebody opens it.

        An all-zero GUID counts as empty: it is what an unmatched control carries on some builds.

    .PARAMETER Page
        The page to inspect, named as Get-PnPPage takes it.

    .PARAMETER ComponentId
        Optional id the attached web part is expected to carry. Supplied by the build commands from
        the component they resolved, so attaching the WRONG component is caught as well as
        attaching none.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Page,

        [string]$ComponentId = ""
    )

    $empty = "00000000-0000-0000-0000-000000000000"
    $controls = @((Get-PnPPage -Identity $Page -ErrorAction Stop).Controls)

    $attached = @($controls | Where-Object {
            $id = ([string](Get-OptionalProperty $_ "WebPartId" "")).Trim("{}").ToLowerInvariant()
            $id -and $id -ne $empty
        })

    if ($attached.Count -eq 0) {
        throw "The web part did not attach to $Page - the control has no WebPartId, so the page would render blank."
    }

    if ($ComponentId) {
        $wanted = $ComponentId.Trim().Trim("{}").ToLowerInvariant()
        $matched = $attached | Where-Object {
            (([string](Get-OptionalProperty $_ "WebPartId" "")).Trim("{}").ToLowerInvariant()) -eq $wanted
        }
        if (-not $matched) {
            $found = ($attached | ForEach-Object { [string](Get-OptionalProperty $_ "WebPartId" "") }) -join ", "
            throw "$Page carries web part(s) $found, not the configured component $wanted."
        }
    }
}

function Get-MarkstrataComponentProbePage {
    <#
    .SYNOPSIS
        Find a page that already exists, to enumerate the site's components against.

    .DESCRIPTION
        Get-PnPAvailablePageComponents needs a page, which makes checking the web part BEFORE
        building anything slightly awkward: the renderer page is the natural probe, and any page in
        the library will do when it is absent.

        Returns an empty string when the pages library holds nothing yet. That is not a failure -
        a site with no pages cannot be pre-flighted, and resolution then happens on the first page
        built, which is where it would have happened anyway.

    .OUTPUTS
        String - a page identity for Get-PnPAvailablePageComponents, or "" when there is none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $config = Get-MarkstrataConfig
    $rendererLeaf = [string](Get-OptionalProperty $config.MarkdownPage "rendererPage" "Wiki.aspx")

    if ($rendererLeaf) {
        try {
            $renderer = Get-PnPPage -Identity $rendererLeaf -ErrorAction Stop
            if ($renderer) { return $rendererLeaf }
        }
        catch {
            Write-Verbose "Renderer page '$rendererLeaf' is not available as a probe: $($_.Exception.Message)"
        }
    }

    try {
        foreach ($item in (Get-PnPListItem -List $config.SharePoint.pagesLibrary -PageSize 100 -ErrorAction Stop)) {
            $leaf = [string]$item.FieldValues.FileLeafRef
            if ($leaf -like "*.aspx") { return $leaf }
        }
    }
    catch {
        Write-Verbose "Could not enumerate the pages library for a probe page: $($_.Exception.Message)"
    }

    return ""
}
