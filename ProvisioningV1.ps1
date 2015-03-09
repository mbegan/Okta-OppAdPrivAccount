param
(
	[ValidateScript({if (Test-Path -PathType Leaf -Path $_) { return $true } else { throw ($_ + " doesn't exist!") }})]
    [string]$path
)

<# The identifier of the Okta Org from the Okta_org.ps1 file #>
[string]$oktaOrg = 'prev'

<# This will be appended to the username when we create our Okta Users #>
[string]$upnAppend = '@varian.com'

<# this is the Identifier of our AD Directory/Application #>
[string]$Directoryaid = '0oa3aktlnubXOcaXH0h7'

<# this is the list of Attributes that are going to be included in our instruction file that we want to pass through to the newly created Okta users #>
[array]$customAttribs = @('city','employeeType','department','employeeID','title','vmsOwnerID','managerId')

<# This is the path we are installing The required Okta Module to #>
[string]$OktaModulePath = "E:\opp\PsModules"

<#
No Edits required below here
#>


if (!(Test-Path -PathType Container -Path ($OktaModulePath + "\Okta") ))
{
    Write-Error 'OktaModulePath is incorrect, Cannot continue'
    sendOutFile -status 'Failure' -internalCode VE0000 -details "OktaModulePath is incorrect, cannot continue"
}
<# Set the Path to include the location of our Okta Module #>
[Environment]::SetEnvironmentVariable("PSModulePath", ( [Environment]::GetEnvironmentVariable("PSModulePath") + ";" + $OktaModulePath ) )
Import-Module okta
if (! (Get-Module -Name 'Okta'))
{
    Write-Error 'Okta Module not installed or available, cannot continue'
    sendOutFile -status 'Failure' -internalCode VE0000 -details "Okta Module not installed or unavailable, cannot continue"
}

[boolean]$createdUser = $false
[boolean]$sent = $false

$tlog = $path.Replace("-input.json","-trace.log")
$elog = $path.Replace("-input.json","-error.log")
[string]$errstatus = $null

function Get-CurrentLineNumber()
{ 
    $MyInvocation.ScriptLineNumber 
}

function getInstruction()
{
    param
    (
        $path
    )
    try
    {
        $filecontent = Get-Content -Raw -Path $path
        $instruction = ConvertFrom-Json -InputObject $filecontent
    }
    catch
    {
        return $false
    }
    #Deal with the pushgroupid 'issue', multivalue (array of string) attributes aren't being sent through the opp agent.
    if ((!$instruction.profile.pushGroupId) -and ($instruction.profile.spushGroupId))
    {
        $pushgroups = $instruction.profile.spushGroupId.split(",")
        Add-Member -InputObject $instruction.profile -MemberType NoteProperty -Name pushGroupId -Value $pushgroups
    }
    $Attributes = New-Object System.Collections.Hashtable
    foreach ($attr in $customAttribs)
    {
        if ($instruction.profile.$attr)
        {
            $_c = $Attributes.add($attr,$instruction.profile.$attr)
        }
    }
    Add-Member -InputObject $instruction -MemberType NoteProperty -Name additional -Value $Attributes
    return $instruction
}

function sendOutFile()
{
    param
    (
        [string]$status,
        [string]$internalCode = 'x201',
        [string]$details = 'SUCCESS',
        [string]$internalId = $null
    )

    $outobj = @{
                status = $status
                internalCode = $internalCode
                details = ( $details + "`r`n" + $errstatus)
                internalId = $internalId
               }
    
    $outTemp = $path.Replace("input.json", "output.temp")
    $outJson = $path.Replace("input.json", "output.json")
    try
    {
        $out = New-Item -Path $outTemp -type file -Force -Value ($outobj | ConvertTo-Json) -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    }
    catch
    {
        throw $_
    }

    if ($Error.Count -ge 1)
    {
        $errout = New-Item -Path $elog -ItemType file -Force -Value ($Error | ConvertTo-Json) -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    }

    if ($status.ToLower() -eq 'success')
    {
        Write-Output ($out.Name)
        $_exitcode = 0
    } else {
        Write-Error ($internalCode + ": " + $details)
        $_exitcode = 1
    }
    Rename-Item -Path $outTemp -NewName $outJson -Force -Confirm:$false
    exit $_exitcode
}

function getUserbyName()
{
    param
    (
        [string]$userName,
        [array]$PossibleUpns = @('varian.com','vms.devqa.varian.com','devqa.varian.com')
    )

    #We assume the bare username version has been tried.
    foreach ($domain in $PossibleUpns)
    {
        try
        {
            $search = $userName + "@" + $domain
            $user = oktaGetUserbyID -oOrg $oktaOrg -uid $search
        }
        catch
        {
            continue
        }
        $Error.Clear()
        return $user
    }
    Throw "User Not Found"
}

function getUser()
{
    param
    (
        [string]$uid,
        [boolean]$full = $false
    )
    try
    {
        #Happy Path, the userName is Unique or it is an OktaID
        $user = oktaGetUserbyID -oOrg $oktaOrg -uid $uid
    }
    catch
    {
        try
        {
            #Do the search by Name
            $user = getUserbyName -userName $uid       
        }
        catch
        {
            return $false
        }
    }
    #I anticipate some errors above, clear and carry on.
    $Error.Clear()

    if ($full)
    {
        $groups = getGroups -oktaId $user.id
        $apps = getApps -oktaId $user.id
    } else {
        $groups = $null
        $apps = $null
    }
    Add-Member -InputObject $user -MemberType NoteProperty -Name groups -Value $groups
    Add-Member -InputObject $user -MemberType NoteProperty -Name apps -Value $apps

    return $user
}

function setGroups()
{
    param
    (
        [object]$user,
        [string]$gid
    )

    if ((!$user.groups) -or ($user.groups -eq $null))
    {
        Add-Member -Force -InputObject $user -MemberType NoteProperty -Name groups -Value (getGroups -oktaId $user.id)
    }

    #Does the user already belong to said group?
    if (!$user.groups.Contains($gid))
    {
        #If not
        #Check to make sure the group is real
        try
        {
            $group = oktaGetGroupbyId -oOrg $oktaOrg -gid $gid
        }
        catch
        {
            #Group doesn't exist
            $group = $false
        }
        #If the group is real, add the user to it.
        if ($group)
        {
            try
            {
                $_c = oktaAddUseridtoGroupid -oOrg $oktaOrg -uid $user.id -gid $gid
                $user.groups.add($group.id,$group)
            }
            catch
            {
                #Failed to add the group
                $user.groups.add($gid,$false)
            }
        }
    }
    return $user
}

function setPassword()
{
    param
    (
        [object]$user,
        [object]$instruction
    )

    $tpass = oktaNewPassword -Length 15 -MustIncludeSets 3
    try
    {
        $tuser = oktaAdminUpdatePasswordbyID -oOrg $oktaOrg -uid $user.id -password $tpass
    }
    catch
    {
        $tuser = $false
        $sent = $false
        $errstatus += "Failed updating the password for the user.`n"
    }
    if ($tuser)
    {
        $subject = "Privileged account [" + $instruction.profile.usernamePrefix + "] for " + $instruction.profile.ownerEmail
        $body = "Please change this at your earliest convenience, it will be automatically expire after 7 days`r`n `r`n `t" + $tpass + "`r`n `r`n Yours truly, Okta`r`n"
        $smtpserver = "mail-relay.us.varian.com"
        try
        {
            $to = $instruction.profile.ownerEmail
            #for now send them all to me
            $to = "megan@varian.com"
            $smtp = Send-MailMessage -From WindowsTeam.VIT@varian.com -To $to -Subject $subject -Body $body -SmtpServer $smtpserver -Priority High
            $sent = $true
        }
        catch
        {
            $smtp = $false
            $sent = $false
            $errstatus += "Failed notifying the user of their password via email.`n"
        }
        $tpass = $null
        $body = $null
    }
    return $sent
}

function getGroups()
{
    param
    (
        [string]$oktaId
    )

    try
    {
        $grouparray = oktaGetGroupsbyUserId -oOrg $oktaOrg -uid $oktaId
        $groups = New-Object System.Collections.Hashtable
        foreach ($g in $grouparray)
        {
            $_c = $groups.add($g.id, $g)
        }

    }
    catch
    {
        $groups = $false
    }
    return $groups
}

function getApps()
{
    param
    (
        [string]$oktaId
    )

    try
    {
        $apparray = oktaGetAppsbyUserId -oOrg $oktaOrg -uid $oktaId
        $apps = New-Object System.Collections.Hashtable
        foreach ($a in $apparray)
        {
            $_c = $apps.add($a.id, $a)
        }
    }
    catch
    {
        $apps = $false
    }
    return $apps
}

function createUser()
{
    param
    (
        [object]$instruction
    )

    #we know the user doesn't exist because nothing would call create user unless it had checked first
    #Die with prejudice if error encountered at create.
    try
    {
        $login = $instruction.userName + $upnAppend
        if ($instruction.profile.ownerEmail -like "*@*.*")
        {
            $email = $instruction.profile.ownerEmail
        } else {
            $email = $login
        }
        $_c = $instruction.additional.add('description', "Account created usering OPP")
        $password = oktaNewPassword -Length 15 -MustIncludeSets 3
        $user = oktaNewUser -oOrg $oktaOrg -login $login -firstName $instruction.userName -lastName $instruction.userName -email $email -password $password -additional $instruction.additional
        $password = $null
    }
    catch
    {
        sendOutFile -status Fail -internalCode VE0002:(Get-CurrentLineNumber) -details ('Failed to create the user: ' + $_)
    }
    sleep -Milliseconds 500
    #Wait for the user to exit transitioning to status
    $user = getUser -full $true -uid $user.id
    while (($user.status -ne 'ACTIVE') -and ($loopcount -le 10))
    {
        $user = getUser -full $true -uid $user.id
        $loopcount++
        sleep -Seconds 1
    }
    $createdUser = $true
    return $user
}

function getOwnerId()
{

}

function updateUser()
{
    param
    (
        [object]$instruction
    )

    <#
    Not sure where i was going with this
    if ($instruction.profile.ownerOktaID -eq "PlaceHolderforOwnerOktaID")
    {
        $ownerusername = $instruction.userName.replace($instruction.profile.usernamePrefix,'')
        $owner = getUser -full $false -uid $ownerusername
        Add-Member -InputObject $instruction.profile -MemberType NoteProperty -Name vmsOwnerID -Value $owner.id -Force
    }
    #>

    #Does the user already exist?
    if ( (!$instruction.externalId) -or ($instruction.externalId -eq $null) -or ($instruction.externalId.ToLower() -eq 'null') )
    {
        $user = getUser -full $true -uid $instruction.userName
    } else {
        $user = getUser -full $true -uid $instruction.externalId
    }

    if (!$user)
    {
        $user = createUser -instruction $instruction
        if (!$user)
        {
            #the user didn't exist, and we failed to create one.
            $errstatus += "The user didn't exist, creating of user failed.`n"
            return $false
        }
    } else {
    <# for not notify an admin of the requirement to update
        #the user already existed, this must be an update. proceed with profileupdate.
        $user.profile.employeeID = $instruction.profile.employeeID
        $user.profile.city = $instruction.profile.city
        $user.profile.department = $instruction.profile.department
        #$user.profile.managerId = $instruction.profile.manager
        $user.profile.title = $instruction.profile.title
        $user.profile.login = ("x" + $instruction.userName + $upnAppend)
        $user.profile.firstName = ("x" + $instruction.userName)
        $user.profile.lastName = ("x" + $instruction.userName)
        $user.profile.email = ("x" + $instruction.profile.ownerEmail)
        try
        {
            oktaUpdateUserProfilebyID -oOrg $oktaOrg -uid $user.id -UpdatedProfile $user.profile
        }
        catch
        {
            write-host nope
        }
    #>
    }

    #we've got the user, see if it belongs to to the provisioning group
    $user = setGroups -user $user -gid $instruction.profile.provisioningGroupID
    #setGroups will never fail, it will just return a user object, check the groups member of the user object to ensure efficacy
    if (!$user.groups.Contains($instruction.profile.provisioningGroupID))
    {
        $errstatus += "Provisioning group (" + $instruction.profile.provisioningGroupID + ") does not exist.`n"
    } elseif (!$user.groups[$instruction.profile.provisioningGroupID])
    {
        $errstatus += "Failed to add user to Provisioning group (" + $instruction.profile.provisioningGroupID + ").`n"
    }

    #we've got the user, user is assigned to the provisioning group. see if it belongs to the push group(s)
    foreach ($pushgroup in $instruction.profile.pushGroupId)
    {
        $user = setGroups -user $user -gid $pushgroup
        if (!$user.groups.Contains($pushgroup))
        {
            $errstatus += "Push group (" + $pushgroup + ") does not exist.`n"
        } elseif (!$user.groups[$pushgroup])
        {
            $errstatus += "Failed to add user to Push group (" + $pushgroup + ").`n"
        }
    }

    #it seems we have the user created, and we've added it (or tried our darndest) to the required groups.
    #Get the user one more time (why not right), if I wasn't getting the user i'd feel compelled to put a sleep in here.
    sleep -Seconds 2
    $user = getUser -full $true -uid $user.id

    if ($createdUser)
    {
        $pass = setPassword -user $user -instruction $instruction
        if (!$pass)
        {
            $errstatus += "Failed to set or notify the user of their password.`n"
        }
    }

    return $user
}

function removeGroups()
{
    param
    (
        [object]$user
    )

    foreach ($g in $user.groups.Keys)
    {
        if ($user.groups.$g.type -eq 'OKTA_GROUP')
        {
            try
            {
                $_c = oktaDeleteUserfromGroup -oOrg $oktaOrg -gid $g -uid $user.id
            }
            catch
            {
                $errstatus += "Failed to remove group (" + $g + ") from the user`n"
            }
        }
    }
    return $user
}

function removeApps()
{
    param
    (
        [object]$user
    )

    foreach ($a in $user.apps.Keys)
    {
        
        #idk
    }

}

function deleteUser()
{
    param
    (
        [object]$instruction
    )

    $user = getUser -full $true -uid $instruction.userName
    if (!$user)
    {
        return $false
    }

    $user = removeGroups -user $user
    sleep -Seconds 1
    #group removals could/should trigger application removal, get a fresh user obj
    $user = getUser -full $true -uid $user.id
    try
    {
        $deactivated = oktaDeactivateuserbyID -oOrg $oktaOrg -uid $user.id
    }
    catch
    {
        $errstatus += "Failed to deactivate the user.`n"
    }
    return $user
}

$instruction = getInstruction -path $path

switch ($instruction.operation.ToLower())
{
    #{(($_ -eq 'create') -or ($_ -eq 'update'))}
    {($_ -eq 'xxxcreate')}
    {
        #Write-Output Create instructins found
        sendOutFile -status Exception -internalCode VCreate1 -details "create: step 1 $_"
    }
    {($_ -eq 'get')}
    {
        #Write-Host Get instructions found
        sendOutFile -status SUCCESS -internalCode VGet1 -details "get: step 2 $_"
    }
    {(($_ -eq 'create') -or ($_ -eq 'update'))}
    {
        #Write-Output update/create instructions found (the actions are the same)
        $user = updateUser -instruction $instruction
        sendOutFile -status SUCCESS -internalCode Vupdate1 -details "update: step 3 $_" -internalId $user.id
    }
    {($_ -eq 'delete')}
    {
        #write-host 'step 4'
        # get user
        # get user groups
        # iterate group memberships and remove the needful or all...
        $user = deleteUser -instruction $instruction
        # set password to something bogus
        # disable the account
        # and cut
        $outfile = sendOutFile -status SUCCESS -internalCode Vupdate1 -details "delete: step 4 $_" -internalId $user.id
        return $outfile
    }
    Default
    {
        #write-host 'default 5'
        $outfile = sendOutFile -status Fail -internalCode Vdefault1 -details "default: undefined action $_"
        return $outfile
    }
}