import { ApolloDownError, Custom404Error, ServerError } from "./fetch-data";

export async function handleError(error: Error): Promise<Response> {
  if (error instanceof Custom404Error) {
    return await getErrorPage(404, "Not Found", error.message);
  } else if (error instanceof ApolloDownError) {
    return await getErrorPage(502, "Bad Gateway");
  } else if (error instanceof ServerError) {
    return await getErrorPage(500, "Internal Server Error", error.message);
  } else {
    throw error;
  }
}
export async function getErrorPage(
  statusCode: number,
  statusText: string,
  message?: string,
): Promise<Response> {
  const port = process.env.PORT ?? 3000;
  let errorPageUrl = `http://localhost:${port}/error?statusCode=${statusCode}&statusText=${encodeURIComponent(
    statusText,
  )}`;
  if (message) {
    errorPageUrl += `&message=${encodeURIComponent(message)}`;
  }

  const errorPage = await fetch(errorPageUrl);
  return new Response(errorPage.body, {
    headers: errorPage.headers,
    status: statusCode,
    statusText,
  });
}
