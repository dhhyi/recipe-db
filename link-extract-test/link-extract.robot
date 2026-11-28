*** Settings ***
Library         Collections
Library         RequestsLibrary

Suite Setup     Wait For Fixture


*** Test Cases ***
Collection Availability Does Not Require Input
    ${response}=    HEAD On Session    link_extract    /link-extract
    Should Be Equal As Integers    ${response.status_code}    204
    Should Be Empty    ${response.text}

Missing Url Is Rejected
    ${response}=    GET On Session    link_extract    /link-extract    expected_status=400
    Problem Envelope Should Match    ${response}    400    Bad Request
    ${body}=    Set Variable    ${response.json()}
    Dictionary Should Contain Item    ${body}    detail    Please provide a url query parameter
    Dictionary Should Contain Item    ${body}    code    missing-query-param

Invalid Url Is Rejected
    &{params}=    Create Dictionary    url=not-a-url
    ${response}=    GET On Session    link_extract    /link-extract    params=${params}    expected_status=400
    Problem Envelope Should Match    ${response}    400    Bad Request
    ${body}=    Set Variable    ${response.json()}
    Dictionary Should Contain Item    ${body}    detail    Please provide a valid url query parameter
    Dictionary Should Contain Item    ${body}    code    invalid-url

Html Metadata Is Extracted
    &{params}=    Create Dictionary    url=%{FIXTURE_API}/page
    ${response}=    GET On Session    link_extract    /link-extract    params=${params}    expected_status=200
    Should Contain    ${response.headers}[Content-Type]    application/json
    ${body}=    Set Variable    ${response.json()}
    Dictionary Should Contain Item    ${body}    url    %{FIXTURE_API}/page
    Dictionary Should Contain Item    ${body}    favicon    %{FIXTURE_API}/favicon.ico
    Dictionary Should Contain Item    ${body}    title    Link Extract Fixture
    Dictionary Should Contain Item    ${body}    description    Fixture page for link extraction
    Dictionary Should Contain Item    ${body}    canonical    %{FIXTURE_API}/canonical

Redirect And Relative Favicon Are Resolved
    &{params}=    Create Dictionary    url=%{FIXTURE_API}/redirect
    ${response}=    GET On Session    link_extract    /link-extract    params=${params}    expected_status=200
    ${body}=    Set Variable    ${response.json()}
    Dictionary Should Contain Item    ${body}    url    %{FIXTURE_API}/redirect
    Dictionary Should Contain Item    ${body}    favicon    %{FIXTURE_API}/favicon.ico
    Dictionary Should Contain Item    ${body}    title    Redirected Fixture

Non Html Response Fails
    &{params}=    Create Dictionary    url=%{FIXTURE_API}/plain
    ${response}=    GET On Session    link_extract    /link-extract    params=${params}    expected_status=500
    Problem Envelope Should Match    ${response}    500    Internal Server Error
    ${body}=    Set Variable    ${response.json()}
    Dictionary Should Contain Item    ${body}    detail    Response is not HTML
    Dictionary Should Contain Item    ${body}    code    fetch-error


*** Keywords ***
Problem Envelope Should Match
    [Arguments]    ${response}    ${status}    ${title}
    Should Be Equal    ${response.headers}[Content-Type]    application/problem+json
    ${body}=    Set Variable    ${response.json()}
    Dictionary Should Contain Item    ${body}    type    about:blank
    Dictionary Should Contain Item    ${body}    title    ${title}
    Should Be Equal As Integers    ${body}[status]    ${status}

Wait For Fixture
    Create Session    link_extract    %{REST_API}
    Create Session    fixture    %{FIXTURE_API}
    Wait Until Keyword Succeeds
    ...    30s
    ...    200ms
    ...    GET On Session
    ...    fixture
    ...    /page
    ...    expected_status=200
    ...    timeout=1
