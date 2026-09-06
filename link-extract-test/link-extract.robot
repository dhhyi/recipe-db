*** Settings ***
Library         Collections
Library         RequestsLibrary

Suite Setup     Create Session    link_extract    %{REST_API}


*** Test Cases ***
Missing Url Is Rejected
    ${response}=    GET On Session    link_extract    /link-extract    expected_status=400
    Should Be Equal As Strings    ${response.text}    Please provide a url query parameter

Invalid Url Is Rejected
    &{params}=    Create Dictionary    url=not-a-url
    ${response}=    GET On Session    link_extract    /link-extract    params=${params}    expected_status=400
    Should Be Equal As Strings    ${response.text}    Please provide a valid url query parameter

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

Canonical Url Uses Cached Metadata
    &{page_params}=    Create Dictionary    url=%{FIXTURE_API}/page
    GET On Session    link_extract    /link-extract    params=${page_params}    expected_status=200
    &{canonical_params}=    Create Dictionary    url=%{FIXTURE_API}/canonical
    ${response}=    GET On Session
    ...    link_extract
    ...    /link-extract
    ...    params=${canonical_params}
    ...    expected_status=200
    ${body}=    Set Variable    ${response.json()}
    Dictionary Should Contain Item    ${body}    url    %{FIXTURE_API}/canonical
    Dictionary Should Contain Item    ${body}    title    Link Extract Fixture

Non Html Response Fails
    &{params}=    Create Dictionary    url=%{FIXTURE_API}/plain
    ${response}=    GET On Session    link_extract    /link-extract    params=${params}    expected_status=500
    Should Be Equal As Strings    ${response.text}    Response is not HTML
